#!/usr/bin/env python3
"""Snapshot Wi-Fi station stats to a world-readable JSON for the guestbook app.

`iw ... station dump` needs root, so this runs (as root) on a systemd timer and
writes /run/portal/stations.json (0644). The web app, which runs unprivileged,
just reads that file — no privilege in the request path.
"""
import json
import os
import re
import subprocess
import sys

IFACE = sys.argv[1] if len(sys.argv) > 1 else "wlan0"
OUT = os.environ.get("PORTAL_STATIONS", "/run/portal/stations.json")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
try:
    txt = subprocess.run(["/usr/sbin/iw", "dev", IFACE, "station", "dump"],
                         capture_output=True, text=True, timeout=5).stdout
except Exception:
    txt = ""

stations, cur = {}, None
for line in txt.splitlines():
    line = line.strip()
    m = re.match(r"Station ([0-9a-fA-F:]{17})", line)
    if m:
        cur = m.group(1).lower()
        stations[cur] = {}
        continue
    if cur is None:
        continue
    if line.startswith("signal:"):
        stations[cur]["signal_dbm"] = int(re.search(r"(-?\d+)", line).group(1))
    elif line.startswith("connected time:"):
        stations[cur]["connected_s"] = int(re.search(r"(\d+)", line).group(1))
    elif line.startswith("rx bytes:"):
        stations[cur]["rx_bytes"] = int(re.search(r"(\d+)", line).group(1))
    elif line.startswith("tx bytes:"):
        stations[cur]["tx_bytes"] = int(re.search(r"(\d+)", line).group(1))
    elif line.startswith("rx bitrate:"):
        stations[cur]["rx_bitrate"] = line.split(":", 1)[1].strip()

tmp = OUT + ".tmp"
with open(tmp, "w") as f:
    json.dump(stations, f)
os.replace(tmp, OUT)
os.chmod(OUT, 0o644)
