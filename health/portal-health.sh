#!/usr/bin/env bash
# Power / USB health snapshot for post-mortem analysis. Runs as root on a timer
# (portal-health.timer); output goes to the journal under SyslogIdentifier
# portal-health. With the persistent journal on, that history survives reboots
# and power loss, so a radio that drops off the bus leaves a trail.
#
#   journalctl -t portal-health              # full history
#   journalctl -t portal-health -p warning   # only the interesting lines
#
# One key=value line per run. Lines are tagged <4> (warning) when the board
# reports under-voltage/throttling or the USB device set / over-current
# counters changed since the last run; otherwise <6> (info).

set -u
STATE="${PORTAL_HEALTH_STATE:-/run/portal-health.last}"

throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
throttled=${throttled:-unknown}
temp=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
volts=$(vcgencmd measure_volts core 2>/dev/null | cut -d= -f2)

# Decode get_throttled: low bits = happening NOW, bits 16+ = happened since boot.
flags=""
if [[ "$throttled" =~ ^0x[0-9a-fA-F]+$ ]]; then
  t=$((throttled))
  (( t & 0x1 ))     && flags+="undervolt_now,"
  (( t & 0x2 ))     && flags+="freqcap_now,"
  (( t & 0x4 ))     && flags+="throttled_now,"
  (( t & 0x8 ))     && flags+="templimit_now,"
  (( t & 0x10000 )) && flags+="undervolt_since_boot,"
  (( t & 0x20000 )) && flags+="freqcap_since_boot,"
  (( t & 0x40000 )) && flags+="throttled_since_boot,"
  (( t & 0x80000 )) && flags+="templimit_since_boot,"
fi
flags=${flags%,}

# USB devices as port=vid:pid@speed (root hub excluded).
usb=""
for d in /sys/bus/usb/devices/[0-9]*-*; do
  [[ -f "$d/idVendor" && "$d" != *:* ]] || continue
  usb+="$(basename "$d")=$(cat "$d/idVendor"):$(cat "$d/idProduct")@$(cat "$d/speed"),"
done
usb=${usb%,}

# Hub port over-current counters; only non-zero ports are listed.
oc=""
for p in /sys/bus/usb/devices/*/*-port*; do
  [[ -f "$p/over_current_count" ]] || continue
  n=$(cat "$p/over_current_count")
  [[ "$n" != "0" ]] && oc+="$(basename "$p")=$n,"
done
oc=${oc%,}

wlan=$(ls /sys/class/net 2>/dev/null | grep '^wlan' | tr '\n' ',' | sed 's/,$//')

key="usb=${usb} oc=${oc}"
prio=6
[[ -n "$flags" ]] && prio=4
if [[ -f "$STATE" && "$(cat "$STATE")" != "$key" ]]; then
  prio=4
  flags="${flags:+$flags,}usb_or_oc_changed"
fi
echo "$key" > "$STATE"

echo "<${prio}>throttled=${throttled} flags=${flags:-none} temp=${temp:-?} core=${volts:-?} wlan=${wlan:-none} ${key}"
