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
    hostapd dnsmasq nginx-light iptables iptables-persistent
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
  render "${SCRIPT_DIR}/config/hostapd.conf.tmpl" /etc/hostapd/hostapd.conf
  # Substitute the security block (multi-line) via awk to avoid sed newline pain.
  awk -v blk="$sec" '{ if ($0=="@SECURITY@") print blk; else print }' \
    /etc/hostapd/hostapd.conf > /etc/hostapd/hostapd.conf.new
  mv /etc/hostapd/hostapd.conf.new /etc/hostapd/hostapd.conf
  chmod 600 /etc/hostapd/hostapd.conf
  sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
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
  render "${SCRIPT_DIR}/config/nginx-portal.conf.tmpl" /etc/nginx/sites-available/portal

  # Fill the @GUESTBOOK_BLOCK@ slot: a proxy location when enabled, else nothing.
  local gb=""
  if [[ "$GUESTBOOK" == "1" ]]; then
    gb=$'    location /guestbook {\n        proxy_pass http://127.0.0.1:8080;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    }'
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
-A INPUT -i ${WLAN_IF} -p tcp --dport 443 -j REJECT --reject-with tcp-reset
-A FORWARD -i ${WLAN_IF} -p tcp --dport 443 -j REJECT --reject-with tcp-reset
COMMIT
RULES
  iptables-restore < /etc/iptables/rules.v4
  # Nowhere to forward to; stray traffic dies at the Pi.
  sysctl -q -w net.ipv4.ip_forward=0
}

start_services() {
  echo "Starting services..."
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
  # /opt/guestbook and /var/lib/portal (the DB) are left in place on purpose so
  # a rollback never destroys signed entries. Remove them by hand if you mean to.
  systemctl disable --now hostapd dnsmasq 2>/dev/null || true
  rm -f /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
  rm -f "/etc/systemd/network/10-${WLAN_IF}-portal.network"
  rm -f /etc/systemd/system/dnsmasq.service.d/after-hostapd.conf
  rm -f /etc/nginx/sites-enabled/portal
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
