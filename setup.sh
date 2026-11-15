#!/usr/bin/env bash
# Captive portal setup — runs ON THE PI, as root.
#
#   sudo ./setup.sh            # install + configure (idempotent, safe to re-run)
#   sudo ./setup.sh rollback   # undo: restore NetworkManager, drop services/rules
#
# Reads ./portal.env for all tunables and renders config/*.tmpl into place.
# See pi2-captive-portal.md for the annotated manual version of every step.
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
# Each rotation restarts hostapd, which briefly drops ALL clients (Portal too),
# so keep this generous. Baits are decoration; they don't need to churn fast.
SSID_ROTATE_INTERVAL="${SSID_ROTATE_INTERVAL:-1h}"
SSID_BAIT_COUNT="${SSID_BAIT_COUNT:-7}"
# 1 = single rotating SSID: one BSS whose name is re-picked from the pool each
# rotation (for radios that only beacon one BSS). Forces baits off.
SSID_ROTATE_PRIMARY="${SSID_ROTATE_PRIMARY:-0}"
# Passwordless sudo for the deploy user (deploy.ps1 runs sudo over a
# non-interactive SSH session with no TTY). 1 = install the NOPASSWD drop-in.
NOPASSWD_SUDO="${NOPASSWD_SUDO:-1}"
# Probe-request logger (monitor mode) — OFF by default; needs a DEDICATED second
# radio (the AP radio can't also monitor). See docs/probe-logging.md.
PROBE_LOG="${PROBE_LOG:-0}"
MONITOR_IF="${MONITOR_IF:-wlan1}"
# Optional MAC->name pinning for multi-radio rigs (see pin_interfaces). Empty =
# no pinning. Use the BURNED-IN MAC: cat /sys/class/ieee80211/phy*/macaddress
WLAN_IF_MAC="${WLAN_IF_MAC:-}"
MONITOR_IF_MAC="${MONITOR_IF_MAC:-}"
PROBE_CHANNELS="${PROBE_CHANNELS:-1,6,11}"
PROBE_HOP="${PROBE_HOP:-1}"
PROBE_HOP_INTERVAL="${PROBE_HOP_INTERVAL:-0.5}"
PROBE_COMMIT_INTERVAL="${PROBE_COMMIT_INTERVAL:-5}"
# Forensics: keep the journal across reboots (Raspberry Pi OS defaults to a
# RAM-only journal, which loses every log on reboot or power loss) and log a
# power/USB health snapshot every minute. See README "Logs & failure analysis".
PERSISTENT_LOGS="${PERSISTENT_LOGS:-1}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-200M}"
JOURNAL_SYNC_INTERVAL="${JOURNAL_SYNC_INTERVAL:-30s}"
HEALTH_LOG="${HEALTH_LOG:-1}"

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
  echo "[1/10] Installing packages..."
  apt-get update -qq
  # iw: needed to manage/inspect the radio (AP-mode verify, and the multi-SSID
  # rotate/cleanup that deletes orphaned wlan0_N bait VIFs). Kept in the base set
  # so multi-SSID works independently of the optional guestbook.
  # tcpdump: kernel-BPF probe-request capture for the optional probe logger.
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    hostapd dnsmasq nginx-light iptables iptables-persistent python3 iw tcpdump
  systemctl unmask hostapd
  systemctl stop hostapd dnsmasq nginx 2>/dev/null || true
}

radio_country() {
  echo "[2/10] Unblocking radio, setting regulatory domain ${COUNTRY}..."
  rfkill unblock wlan || true
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "${COUNTRY}" || true
  fi
}

# ── pin_interfaces: lock each USB radio to a fixed netdev name by its ──────────
# BURNED-IN MAC, so two dongles never swap wlan0/wlan1 across reboots, USB
# ports, or a powered hub (we match the hardware MAC, never the fragile USB
# path). Optional: skipped entirely if no *_IF_MAC is set (single-radio rigs
# don't need it). Match on PermanentMACAddress, not MACAddress, because hostapd
# reassigns the AP radio's running MAC to its BSSID at runtime.
pin_interfaces() {
  echo "[3/10] Pinning Wi-Fi interface names by MAC..."
  if [[ -z "${WLAN_IF_MAC}" && -z "${MONITOR_IF_MAC}" ]]; then
    echo "      (no *_IF_MAC set in portal.env; leaving kernel naming as-is)"
    return 0
  fi
  _pin_one() {  # $1=mac  $2=target ifname  $3=source var name (for the comment)
    [[ -z "$1" ]] && return 0
    cat >"/etc/systemd/network/10-${2}-pin.link" <<EOF
# Pin ${2} to its radio by burned-in MAC — survives reboot / USB reorder / hub.
# Managed by setup.sh from ${3}=${1} in portal.env; edit there, not here.
[Match]
PermanentMACAddress=${1}

[Link]
Name=${2}
EOF
    echo "      ${2} <- ${1}"
  }
  _pin_one "${WLAN_IF_MAC}"    "${WLAN_IF}"    "WLAN_IF_MAC"
  _pin_one "${MONITOR_IF_MAC}" "${MONITOR_IF}" "MONITOR_IF_MAC"
  # udev applies the rename at device appearance; we don't re-trigger here so a
  # live AP isn't renamed out from under hostapd. Effective on next reboot.
  echo "      (effective on next reboot; not renaming live interfaces now)"
}

nm_unmanage() {
  echo "[4/10] Marking ${WLAN_IF} unmanaged by NetworkManager..."
  render "${SCRIPT_DIR}/config/99-portal-unmanaged.conf.tmpl" \
         /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
  systemctl reload NetworkManager 2>/dev/null || true
}

static_ip() {
  echo "[5/10] Static IP ${PORTAL_IP}/${PREFIX} on ${WLAN_IF} via systemd-networkd..."
  render "${SCRIPT_DIR}/config/10-wlan0-portal.network.tmpl" \
         "/etc/systemd/network/10-${WLAN_IF}-portal.network"
  systemctl enable --now systemd-networkd
}

configure_hostapd() {
  echo "[6/10] hostapd (SSID '${SSID}', channel ${CHANNEL})..."
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
SSID_ROTATE_PRIMARY=${SSID_ROTATE_PRIMARY}
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

  # Reap orphaned bait VIFs (wlan0_N) before every hostapd start. hostapd creates
  # them but never deletes them, so without this they pile up across restarts.
  # '-' ignores errors (e.g. nothing to remove); runs as root with hostapd.
  mkdir -p /etc/systemd/system/hostapd.service.d
  cat > /etc/systemd/system/hostapd.service.d/portal-cleanup.conf <<'DROPIN'
[Service]
ExecStartPre=-/usr/bin/python3 /opt/portal-ssid-rotate.py --cleanup-only
DROPIN

  systemctl daemon-reload

  if [[ "$SSID_ROTATE" == "1" && "$n_pool" -gt 0 ]]; then
    systemctl enable --now portal-ssid-rotate.timer
    if [[ "$SSID_ROTATE_PRIMARY" == "1" ]]; then
      echo "      rotation: ON every ${SSID_ROTATE_INTERVAL} (single SSID cycling ${n_pool} names)"
    else
      echo "      rotation: ON every ${SSID_ROTATE_INTERVAL} (${SSID_BAIT_COUNT} of ${n_pool} baits live)"
    fi
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
  echo "[7/10] dnsmasq (DHCP + wildcard DNS)..."
  [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.orig ]] && \
    mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
  render "${SCRIPT_DIR}/config/dnsmasq.conf.tmpl" /etc/dnsmasq.conf
  # Free port 53 if systemd-resolved's stub is holding it.
  if ss -ulnp 2>/dev/null | grep -q ':53 .*systemd-resolve'; then
    echo "      systemd-resolved holds :53 — disabling it"
    systemctl disable --now systemd-resolved || true
  fi
  # dnsmasq starts after hostapd brings up the carrier and networkd the IP.
  # Wants (not Requires): DHCP must survive hostapd flaps. With Requires, a
  # hostapd crash-loop blocked dnsmasq from ever starting, and every SSID
  # rotation (systemctl restart hostapd) tore dnsmasq down and left it dead —
  # clients then got no lease. Wants keeps dnsmasq serving across restarts;
  # After= still orders it so the initial bind-interfaces sees wlan0 up.
  mkdir -p /etc/systemd/system/dnsmasq.service.d
  cat > /etc/systemd/system/dnsmasq.service.d/after-hostapd.conf <<'DROPIN'
[Unit]
After=hostapd.service
Wants=hostapd.service
DROPIN
  systemctl daemon-reload
}

configure_portal_page() {
  echo "[8/10] Portal page -> /var/www/portal/..."
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
  echo "[9/10] nginx..."
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
  echo "[10/10] Firewall rules (idempotent via iptables-restore)..."
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

install_sudoers() {
  echo "[0/10] Passwordless sudo for the deploy user..."
  # deploy.ps1 runs `sudo` over a non-interactive SSH session that has no TTY to
  # type a password into. Grant NOPASSWD to the invoking user so every deploy
  # after the first (which is interactive via `ssh -t`) runs unattended. Opt out
  # with NOPASSWD_SUDO=0 in portal.env.
  local u="${SUDO_USER:-${DEPLOY_USER:-}}"
  if [[ -z "$u" || "$u" == "root" ]]; then
    echo "      skipped: no non-root deploy user detected (SUDO_USER unset)."
    return 0
  fi
  local f=/etc/sudoers.d/011_pi-nopasswd
  local tmp; tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" > "$tmp"
  # Validate BEFORE installing — a bad sudoers file can lock you out of sudo.
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 440 -o root -g root "$tmp" "$f"
    echo "      enabled for '${u}' (${f})"
  else
    echo "ERROR: generated sudoers file failed visudo validation; not installed." >&2
  fi
  rm -f "$tmp"
}

install_probe() {
  echo "[8b/9] Probe-request logger (monitor mode)..."
  if [[ "$PROBE_LOG" != "1" ]]; then
    # Disabled: tear down any prior install so toggling PROBE_LOG=0 is clean.
    systemctl disable --now portal-probe-logger.service 2>/dev/null || true
    rm -f /etc/systemd/system/portal-probe-logger.service /opt/portal-probe-logger.py \
          /etc/portal-probe.env /etc/NetworkManager/conf.d/99-portal-probe-unmanaged.conf
    systemctl daemon-reload
    echo "      probe logging: OFF (PROBE_LOG=0)"
    return 0
  fi
  if [[ "$MONITOR_IF" == "$WLAN_IF" ]]; then
    echo "ERROR: MONITOR_IF ('$MONITOR_IF') must differ from the AP's WLAN_IF" >&2
    echo "       ('$WLAN_IF'). Probe logging needs its own radio; skipping." >&2
    return 0
  fi

  cat > /etc/portal-probe.env <<PROBEENV
MONITOR_IF=${MONITOR_IF}
PROBE_DB=/var/lib/portal/probes.db
PROBE_CHANNELS=${PROBE_CHANNELS}
PROBE_HOP=${PROBE_HOP}
PROBE_HOP_INTERVAL=${PROBE_HOP_INTERVAL}
PROBE_COMMIT_INTERVAL=${PROBE_COMMIT_INTERVAL}
PROBEENV
  chmod 600 /etc/portal-probe.env
  install -m 755 "${SCRIPT_DIR}/probe/portal-probe-logger.py" /opt/portal-probe-logger.py

  # Keep the monitor radio out of NetworkManager's hands (like the AP radio).
  cat > /etc/NetworkManager/conf.d/99-portal-probe-unmanaged.conf <<NMCONF
[keyfile]
unmanaged-devices=interface-name:${MONITOR_IF}
NMCONF
  systemctl reload NetworkManager 2>/dev/null || true

  cp -f "${SCRIPT_DIR}/probe/portal-probe-logger.service" \
    /etc/systemd/system/portal-probe-logger.service
  systemctl daemon-reload
  systemctl enable --now portal-probe-logger.service
  echo "      probe logging: ON, monitor=${MONITOR_IF} channels=${PROBE_CHANNELS}"
  echo "      view: sudo python3 /opt/portal-probe-logger.py --report"
}

configure_logging() {
  echo "[0b/10] Persistent logs + power/USB health logger..."
  # Raspberry Pi OS ships /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
  # (Storage=volatile). A later-sorting drop-in in /etc overrides it.
  local dropin=/etc/systemd/journald.conf.d/50-portal-persistent.conf
  if [[ "$PERSISTENT_LOGS" == "1" ]]; then
    install -d /etc/systemd/journald.conf.d
    # SyncIntervalSec: how much un-flushed log a sudden power cut can lose
    # (default 5min). Shorter costs a little SD-card wear.
    cat > "$dropin" <<JOURNALD
[Journal]
Storage=persistent
SystemMaxUse=${JOURNAL_MAX_USE}
SyncIntervalSec=${JOURNAL_SYNC_INTERVAL}
JOURNALD
    install -d -m 2755 -g systemd-journal /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
    echo "      journal: persistent (/var/log/journal, max ${JOURNAL_MAX_USE})"
  else
    # Back to the Pi OS default (RAM only). Existing /var/log/journal files are
    # left in place; they may be evidence.
    if [[ -f "$dropin" ]]; then
      rm -f "$dropin"
      systemctl restart systemd-journald
    fi
    echo "      journal: volatile (PERSISTENT_LOGS=0)"
  fi

  if [[ "$HEALTH_LOG" == "1" ]]; then
    install -m 755 "${SCRIPT_DIR}/health/portal-health.sh" /opt/portal-health.sh
    cp -f "${SCRIPT_DIR}/health/portal-health.service" /etc/systemd/system/portal-health.service
    cp -f "${SCRIPT_DIR}/health/portal-health.timer"   /etc/systemd/system/portal-health.timer
    systemctl daemon-reload
    systemctl enable --now portal-health.timer
    echo "      health log: ON (journalctl -t portal-health)"
  else
    systemctl disable --now portal-health.timer 2>/dev/null || true
    rm -f /etc/systemd/system/portal-health.service /etc/systemd/system/portal-health.timer \
          /opt/portal-health.sh
    systemctl daemon-reload
    echo "      health log: OFF (HEALTH_LOG=0)"
  fi
}

do_install() {
  [[ "$NOPASSWD_SUDO" == "1" ]] && install_sudoers
  # First, so the rest of the install (and any failure in it) is captured.
  configure_logging
  install_packages
  radio_country
  pin_interfaces
  nm_unmanage
  static_ip
  configure_hostapd
  configure_ssid
  configure_dnsmasq
  configure_portal_page
  [[ "$GUESTBOOK" == "1" ]] && install_guestbook
  install_probe
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
  rm -f /etc/systemd/system/hostapd.service.d/portal-cleanup.conf
  rmdir /etc/systemd/system/hostapd.service.d 2>/dev/null || true
  systemctl disable --now portal-probe-logger.service 2>/dev/null || true
  rm -f /etc/systemd/system/portal-probe-logger.service /opt/portal-probe-logger.py
  rm -f /etc/portal-probe.env /etc/NetworkManager/conf.d/99-portal-probe-unmanaged.conf
  # /var/lib/portal/probes.db is left in place (like the guestbook DB).
  systemctl disable --now portal-health.timer 2>/dev/null || true
  rm -f /etc/systemd/system/portal-health.service /etc/systemd/system/portal-health.timer
  rm -f /opt/portal-health.sh /run/portal-health.last
  # Journal returns to the Pi OS default (volatile). /var/log/journal is left in
  # place so collected history is not destroyed by a rollback.
  rm -f /etc/systemd/journald.conf.d/50-portal-persistent.conf
  systemctl restart systemd-journald 2>/dev/null || true
  # Undo the passwordless-sudo drop-in this setup installed (deploy infra, not
  # portal runtime — a fresh `setup.sh install` re-adds it via `ssh -t`).
  rm -f /etc/sudoers.d/011_pi-nopasswd
  # /opt/guestbook and /var/lib/portal (the DB) are left in place on purpose so
  # a rollback never destroys signed entries. Remove them by hand if you mean to.
  systemctl disable --now hostapd dnsmasq 2>/dev/null || true
  rm -f /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
  rm -f "/etc/systemd/network/10-${WLAN_IF}-portal.network"
  rm -f "/etc/systemd/network/10-${WLAN_IF}-pin.link" "/etc/systemd/network/10-${MONITOR_IF}-pin.link"
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
