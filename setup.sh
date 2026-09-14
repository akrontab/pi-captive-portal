#!/usr/bin/env bash
# Captive portal setup — runs ON THE PI, as root.
#
#   sudo ./setup.sh            # install + configure (idempotent, safe to re-run)
#   sudo ./setup.sh rollback   # undo: restore NetworkManager, drop services/rules
#
# Reads ./portal.env for all tunables and renders config/*.tmpl into place.
# See pi3-captive-portal.md for the annotated manual version of every step.
#
# WARNING: this takes wlan0 away from NetworkManager. Run it over ETHERNET or a
# directly attached keyboard, never over the Wi-Fi you're about to repurpose.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/portal.env"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./setup.sh)" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy portal.env.example to portal.env and edit it." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${WLAN_IF:?}"; : "${SSID:?}"; : "${COUNTRY:?}"; : "${CHANNEL:?}"
: "${PORTAL_IP:?}"; : "${NETMASK:?}"; : "${PREFIX:?}"
: "${DHCP_START:?}"; : "${DHCP_END:?}"; : "${DHCP_LEASE:?}"
WPA_PASSPHRASE="${WPA_PASSPHRASE:-}"
GUESTBOOK="${GUESTBOOK:-0}"
SSID_ROTATE="${SSID_ROTATE:-1}"
SSID_ROTATE_INTERVAL="${SSID_ROTATE_INTERVAL:-2min}"
SSID_BAIT_COUNT="${SSID_BAIT_COUNT:-7}"

# Portal subnet as CIDR (network address / prefix), derived from PORTAL_IP+PREFIX.
# Used to let the guestbook dump endpoint be reached from portal clients.
IFS=. read -r _a _b _c _d <<<"$PORTAL_IP"
_ipn=$(( (_a<<24)|(_b<<16)|(_c<<8)|_d ))
_maskn=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
_netn=$(( _ipn & _maskn ))
PORTAL_NET="$(( (_netn>>24)&255 )).$(( (_netn>>16)&255 )).$(( (_netn>>8)&255 )).$(( _netn&255 ))/${PREFIX}"

# ── render: expand @TOKEN@ placeholders from portal.env into a file ────────────
render() {
  local src="$1" dst="$2"
  sed \
    -e "s|@WLAN_IF@|${WLAN_IF}|g" \
    -e "s|@SSID@|${SSID}|g" \
    -e "s|@COUNTRY@|${COUNTRY}|g" \
    -e "s|@CHANNEL@|${CHANNEL}|g" \
    -e "s|@PORTAL_IP@|${PORTAL_IP}|g" \
    -e "s|@NETMASK@|${NETMASK}|g" \
    -e "s|@PREFIX@|${PREFIX}|g" \
    -e "s|@DHCP_START@|${DHCP_START}|g" \
    -e "s|@DHCP_END@|${DHCP_END}|g" \
    -e "s|@DHCP_LEASE@|${DHCP_LEASE}|g" \
    "$src" > "$dst"
}

install_packages() {
  echo "[1/9] Installing packages..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    hostapd dnsmasq nginx-light iptables iptables-persistent python3
  systemctl unmask hostapd
  systemctl stop hostapd dnsmasq nginx 2>/dev/null || true
}

radio_country() {
  echo "[2/9] Unblocking radio, setting regulatory domain ${COUNTRY}..."
  rfkill unblock wlan || true
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "${COUNTRY}" || true
  fi
}

nm_unmanage() {
  echo "[3/9] Marking ${WLAN_IF} unmanaged by NetworkManager..."
  render "${SCRIPT_DIR}/config/99-portal-unmanaged.conf.tmpl" \
         /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
  systemctl reload NetworkManager 2>/dev/null || true
}

static_ip() {
  echo "[4/9] Static IP ${PORTAL_IP}/${PREFIX} on ${WLAN_IF} via systemd-networkd..."
  render "${SCRIPT_DIR}/config/10-wlan0-portal.network.tmpl" \
         "/etc/systemd/network/10-${WLAN_IF}-portal.network"
  systemctl enable --now systemd-networkd
}

configure_hostapd() {
  echo "[5/9] hostapd (SSID '${SSID}', channel ${CHANNEL})..."
  local sec
  if [[ -n "$WPA_PASSPHRASE" ]]; then
    if (( ${#WPA_PASSPHRASE} < 8 || ${#WPA_PASSPHRASE} > 63 )); then
      echo "ERROR: WPA_PASSPHRASE must be 8-63 chars." >&2; exit 1
    fi
    sec=$'auth_algs=1\nwpa=2\nwpa_passphrase='"${WPA_PASSPHRASE}"$'\nwpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP'
    echo "      security: WPA2"
  else
    sec=$'auth_algs=1\nwpa=0'
    echo "      security: OPEN"
  fi
  # Render the PRIMARY BSS (the stable "Portal") + security into a base file.
  # The live /etc/hostapd/hostapd.conf is (re)built from this base by
  # configure_ssid / portal-ssid-rotate.py, which append the bait BSSes after it.
  local base=/etc/hostapd/hostapd.base.conf
  render "${SCRIPT_DIR}/config/hostapd.conf.tmpl" "$base"
  # Substitute the security block (multi-line) via awk to avoid sed newline pain.
  awk -v blk="$sec" '{ if ($0=="@SECURITY@") print blk; else print }' \
    "$base" > "${base}.new"
  mv "${base}.new" "$base"
  chmod 600 "$base"
  sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
}

configure_ssid() {
  echo "[5b/9] Multi-SSID / bait rotation..."
  local pool_src="${SCRIPT_DIR}/ssids.txt"
  local pool_dst=/etc/portal-ssids.txt
  local n_pool=0
  if [[ -f "$pool_src" ]]; then
    install -m 644 "$pool_src" "$pool_dst"
    n_pool=$(grep -vcE '^[[:space:]]*(#|$)' "$pool_dst" || true)
  else
    rm -f "$pool_dst"
  fi

  # Config for the rotate engine (it reads this file directly; systemd runs it too).
  cat > /etc/portal-ssid.env <<SSIDENV
WLAN_IF=${WLAN_IF}
SSID_POOL_FILE=${pool_dst}
SSID_BAIT_COUNT=${SSID_BAIT_COUNT}
PRIMARY_SSID=${SSID}
HOSTAPD_BASE=/etc/hostapd/hostapd.base.conf
HOSTAPD_CONF=/etc/hostapd/hostapd.conf
SSIDENV
  chmod 600 /etc/portal-ssid.env

  install -m 755 "${SCRIPT_DIR}/ssid/portal-ssid-rotate.py" /opt/portal-ssid-rotate.py

  # Build the live hostapd.conf now (base + an initial bait set). hostapd is
  # started later by start_services, so do not restart it here.
  python3 /opt/portal-ssid-rotate.py --no-restart

  cp -f "${SCRIPT_DIR}/ssid/portal-ssid-rotate.service" /etc/systemd/system/portal-ssid-rotate.service
  cp -f "${SCRIPT_DIR}/ssid/portal-ssid-rotate.timer"   /etc/systemd/system/portal-ssid-rotate.timer
  sed -i "s|^OnUnitActiveSec=.*|OnUnitActiveSec=${SSID_ROTATE_INTERVAL}|" \
    /etc/systemd/system/portal-ssid-rotate.timer
  systemctl daemon-reload

  if [[ "$SSID_ROTATE" == "1" && "$n_pool" -gt 0 ]]; then
    systemctl enable --now portal-ssid-rotate.timer
    echo "      rotation: ON every ${SSID_ROTATE_INTERVAL} (${SSID_BAIT_COUNT} of ${n_pool} baits live)"
  else
    systemctl disable --now portal-ssid-rotate.timer 2>/dev/null || true
    if [[ "$n_pool" -gt 0 ]]; then
      echo "      rotation: OFF (static ${SSID_BAIT_COUNT} of ${n_pool} baits)"
    else
      echo "      rotation: OFF (no ssids.txt -> single SSID '${SSID}')"
    fi
  fi
}

configure_dnsmasq() {
  echo "[6/9] dnsmasq (DHCP + wildcard DNS)..."
  [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.orig ]] && \
    mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
  render "${SCRIPT_DIR}/config/dnsmasq.conf.tmpl" /etc/dnsmasq.conf
  # Free port 53 if systemd-resolved's stub is holding it.
  if ss -ulnp 2>/dev/null | grep -q ':53 .*systemd-resolve'; then
    echo "      systemd-resolved holds :53 — disabling it"
    systemctl disable --now systemd-resolved || true
  fi
  # dnsmasq must start after hostapd brings up the carrier and networkd the IP.
  mkdir -p /etc/systemd/system/dnsmasq.service.d
  cat > /etc/systemd/system/dnsmasq.service.d/after-hostapd.conf <<'DROPIN'
[Unit]
After=hostapd.service
Requires=hostapd.service
DROPIN
  systemctl daemon-reload
}

configure_portal_page() {
  echo "[7/9] Portal page -> /var/www/portal/..."
  mkdir -p /var/www/portal
  install -m 644 "${SCRIPT_DIR}/www/"* /var/www/portal/
}

install_guestbook() {
  echo "[guestbook] Installing Flask/gunicorn guestbook..."
  # iw: used by the Wi-Fi station-stats sidecar for device fingerprinting.
  apt-get install -y -qq python3 python3-venv iw
  # DB lives outside the app dir so redeploys never clobber it.
  install -d -o www-data -g www-data /var/lib/portal

  # Service config env file (systemd EnvironmentFile), owned by the service user.
  ( umask 077
    cat > /etc/guestbook.env <<ENVEOF
GUESTBOOK_DB=/var/lib/portal/guestbook.db
ENVEOF
  )
  chown www-data:www-data /etc/guestbook.env
  chmod 600 /etc/guestbook.env

  mkdir -p /opt/guestbook
  cp -f "${SCRIPT_DIR}/guestbook/app.py" /opt/guestbook/
  cp -f "${SCRIPT_DIR}/guestbook/requirements.txt" /opt/guestbook/
  cp -f "${SCRIPT_DIR}/guestbook/portal-stations.py" /opt/guestbook/
  rm -rf /opt/guestbook/templates
  cp -rf "${SCRIPT_DIR}/guestbook/templates" /opt/guestbook/

  [[ -d /opt/guestbook/.venv ]] || python3 -m venv /opt/guestbook/.venv
  /opt/guestbook/.venv/bin/pip install --quiet --upgrade pip
  /opt/guestbook/.venv/bin/pip install --quiet -r /opt/guestbook/requirements.txt
  chown -R www-data:www-data /opt/guestbook

  cp -f "${SCRIPT_DIR}/guestbook/guestbook.service" /etc/systemd/system/guestbook.service

  # Wi-Fi station-stats sidecar: runs as root on a timer, writes a world-readable
  # snapshot the (unprivileged) web app reads. Keeps privilege out of the app.
  cp -f "${SCRIPT_DIR}/guestbook/portal-stations.service" /etc/systemd/system/portal-stations.service
  cp -f "${SCRIPT_DIR}/guestbook/portal-stations.timer"   /etc/systemd/system/portal-stations.timer

  systemctl daemon-reload
  systemctl enable guestbook
  systemctl restart guestbook
  systemctl enable --now portal-stations.timer
  systemctl start portal-stations.service   # seed the first snapshot now
}

configure_nginx() {
  echo "[8/9] nginx..."
  rm -f /etc/nginx/sites-enabled/default
  # http-context rate-limit zone (limit_req_zone can't live in a server block).
  cat > /etc/nginx/conf.d/portal-hardening.conf <<'RLZONE'
limit_req_zone $binary_remote_addr zone=portal_sign:10m rate=5r/s;
RLZONE
  render "${SCRIPT_DIR}/config/nginx-portal.conf.tmpl" /etc/nginx/sites-available/portal

  # Fill the @GUESTBOOK_BLOCK@ slot: a proxy location when enabled, else nothing.
  local gb=""
  if [[ "$GUESTBOOK" == "1" ]]; then
    # Exact-match locations win over the /guestbook prefix. sign is rate-limited.
    # dump (captured fingerprint data) is reachable from localhost and the portal
    # network (${PORTAL_NET}); denied to everything else. NOTE: this deliberately
    # lets any client on the portal Wi-Fi pull every visitor's MAC/hostname/UA.
    # Off the portal net, pull it with `deploy.ps1 -PullJson` / `-PullGuestbook`.
    gb=$'    location = /guestbook/sign {\n        limit_req zone=portal_sign burst=10 nodelay;\n        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    }\n    location = /guestbook/dump {\n        allow 127.0.0.1;\n        allow ::1;\n        allow '"${PORTAL_NET}"$';\n        deny all;\n        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    }\n    location /guestbook {\n        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    }'
  fi
  awk -v blk="$gb" '{ if ($0=="@GUESTBOOK_BLOCK@") { if (blk!="") print blk } else print }' \
    /etc/nginx/sites-available/portal > /etc/nginx/sites-available/portal.new
  mv /etc/nginx/sites-available/portal.new /etc/nginx/sites-available/portal

  ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
  nginx -t
}

configure_firewall() {
  echo "[9/9] Firewall rules (idempotent via iptables-restore)..."
  mkdir -p /etc/iptables
  cat > /etc/iptables/rules.v4 <<RULES
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -i ${WLAN_IF} -p udp --dport 53 -j REDIRECT --to-ports 53
-A PREROUTING -i ${WLAN_IF} -p tcp --dport 53 -j REDIRECT --to-ports 53
-A PREROUTING -i ${WLAN_IF} -p tcp --dport 80 -j DNAT --to-destination ${PORTAL_IP}:80
COMMIT
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
# Loopback + return traffic.
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Only the services portal clients legitimately need are open on ${WLAN_IF}.
-A INPUT -i ${WLAN_IF} -p udp --dport 67 -j ACCEPT
-A INPUT -i ${WLAN_IF} -p udp --dport 53 -j ACCEPT
-A INPUT -i ${WLAN_IF} -p tcp --dport 53 -j ACCEPT
-A INPUT -i ${WLAN_IF} -p tcp --dport 80 -j ACCEPT
# Fast-fail HTTPS so captive detection doesn't hang (we never MITM TLS).
-A INPUT -i ${WLAN_IF} -p tcp --dport 443 -j REJECT --reject-with tcp-reset
# Drop everything else from the hostile client network (SSH, gunicorn:8080, ...).
# Management/SSH stays reachable over the WIRED interface, which is untouched.
-A INPUT -i ${WLAN_IF} -j DROP
-A FORWARD -i ${WLAN_IF} -p tcp --dport 443 -j REJECT --reject-with tcp-reset
COMMIT
RULES
  iptables-restore < /etc/iptables/rules.v4
  # Nowhere to forward to; stray traffic dies at the Pi.
  sysctl -q -w net.ipv4.ip_forward=0
}

start_services() {
  echo "Starting services..."
  # Clear any prior failed/rate-limited state (e.g. a hostapd restart loop from
  # a bad config) so the restarts below aren't blocked by systemd's start limit.
  systemctl reset-failed hostapd dnsmasq nginx 2>/dev/null || true
  systemctl enable --now hostapd
  systemctl enable --now dnsmasq
  systemctl enable --now nginx
  systemctl restart hostapd dnsmasq nginx
  echo ""
  systemctl --no-pager --lines=0 status hostapd dnsmasq nginx || true
}

do_install() {
  install_packages
  radio_country
  nm_unmanage
  static_ip
  configure_hostapd
  configure_ssid
  configure_dnsmasq
  configure_portal_page
  [[ "$GUESTBOOK" == "1" ]] && install_guestbook
  configure_nginx
  configure_firewall
  start_services
  echo ""
  echo "Done. SSID '${SSID}' should be broadcasting. Portal at http://${PORTAL_IP}/portal"
  [[ "$GUESTBOOK" == "1" ]] && echo "Guestbook at http://${PORTAL_IP}/guestbook"
  echo "Verify:  iw dev ${WLAN_IF} info | grep type   # expect: type AP"
  echo "         dig @127.0.0.1 example.com +short    # expect: ${PORTAL_IP}"
}

do_rollback() {
  echo "Rolling back captive portal..."
  systemctl disable --now guestbook 2>/dev/null || true
  systemctl disable --now portal-stations.timer 2>/dev/null || true
  rm -f /etc/systemd/system/guestbook.service
  rm -f /etc/systemd/system/portal-stations.service /etc/systemd/system/portal-stations.timer
  systemctl disable --now portal-ssid-rotate.timer 2>/dev/null || true
  rm -f /etc/systemd/system/portal-ssid-rotate.service /etc/systemd/system/portal-ssid-rotate.timer
  rm -f /opt/portal-ssid-rotate.py /etc/portal-ssid.env /etc/portal-ssids.txt
  rm -f /etc/hostapd/hostapd.base.conf
  # /opt/guestbook and /var/lib/portal (the DB) are left in place on purpose so
  # a rollback never destroys signed entries. Remove them by hand if you mean to.
  systemctl disable --now hostapd dnsmasq 2>/dev/null || true
  rm -f /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
  rm -f "/etc/systemd/network/10-${WLAN_IF}-portal.network"
  rm -f /etc/systemd/system/dnsmasq.service.d/after-hostapd.conf
  rm -f /etc/nginx/sites-enabled/portal
  rm -f /etc/nginx/conf.d/portal-hardening.conf
  [[ -f /etc/dnsmasq.conf.orig ]] && mv -f /etc/dnsmasq.conf.orig /etc/dnsmasq.conf
  systemctl daemon-reload
  systemctl reload NetworkManager 2>/dev/null || true
  iptables -F; iptables -t nat -F
  : > /etc/iptables/rules.v4 || true
  netfilter-persistent save 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true
  echo "Rolled back. ${WLAN_IF} returned to NetworkManager."
}

case "${1:-install}" in
  install)  do_install ;;
  rollback) do_rollback ;;
  *) echo "usage: $0 [install|rollback]" >&2; exit 2 ;;
esac
