#!/usr/bin/env python3
"""Render hostapd's live config from a base file + a bait-SSID selection.

The primary SSID (the stable "Portal") lives in the base config as the first
BSS. This script appends up to SSID_BAIT_COUNT extra `bss=` stanzas — chosen at
random from a pool file — and (unless --no-restart) restarts hostapd so the new
bait set goes live. Run periodically by portal-ssid-rotate.timer to reshuffle.

Config comes from /etc/portal-ssid.env (KEY=VALUE); real environment variables
override it. Keys: WLAN_IF, SSID_POOL_FILE, SSID_BAIT_COUNT, PRIMARY_SSID,
HOSTAPD_BASE, HOSTAPD_CONF. All privileged work runs as root from the timer.
"""
import os
import random
import subprocess
import sys

ENV_FILE = os.environ.get("PORTAL_SSID_ENV", "/etc/portal-ssid.env")
KEYS = ("WLAN_IF", "SSID_POOL_FILE", "SSID_BAIT_COUNT", "PRIMARY_SSID",
        "HOSTAPD_BASE", "HOSTAPD_CONF")
# rt2800usb tops out at 8 BSSes on one channel; primary is one, so 7 baits max.
MAX_BAITS = 7
SSID_MAX_OCTETS = 32


def load_config():
    cfg = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    for k in KEYS:                      # real env wins over the file
        if k in os.environ:
            cfg[k] = os.environ[k]
    cfg.setdefault("WLAN_IF", "wlan0")
    cfg.setdefault("SSID_POOL_FILE", "/etc/portal-ssids.txt")
    cfg.setdefault("SSID_BAIT_COUNT", str(MAX_BAITS))
    cfg.setdefault("PRIMARY_SSID", "")
    cfg.setdefault("HOSTAPD_BASE", "/etc/hostapd/hostapd.base.conf")
    cfg.setdefault("HOSTAPD_CONF", "/etc/hostapd/hostapd.conf")
    return cfg


def read_pool(path, primary):
    """Clean, de-duplicated bait names from the pool file (minus the primary)."""
    seen, pool = set(), []
    try:
        with open(path) as f:
            for line in f:
                name = line.rstrip("\n")
                if not name.strip() or name.lstrip().startswith("#"):
                    continue
                if len(name.encode("utf-8")) > SSID_MAX_OCTETS:
                    continue           # SSID is max 32 octets; skip the rest
                if name == primary or name in seen:
                    continue
                seen.add(name)
                pool.append(name)
    except FileNotFoundError:
        pass
    return pool


def build_conf(base_text, iface, baits):
    parts = [base_text.rstrip("\n"), ""]
    for i, name in enumerate(baits):
        parts += [f"bss={iface}_{i}", f"ssid={name}", "ignore_broadcast_ssid=0", ""]
    return "\n".join(parts) + "\n"


def main():
    no_restart = "--no-restart" in sys.argv[1:]
    cfg = load_config()

    try:
        count = int(cfg["SSID_BAIT_COUNT"])
    except ValueError:
        count = MAX_BAITS
    count = max(0, min(count, MAX_BAITS))

    with open(cfg["HOSTAPD_BASE"]) as f:
        base_text = f.read()

    pool = read_pool(cfg["SSID_POOL_FILE"], cfg["PRIMARY_SSID"])
    baits = random.sample(pool, min(count, len(pool))) if (pool and count) else []

    conf = build_conf(base_text, cfg["WLAN_IF"], baits)
    dst = cfg["HOSTAPD_CONF"]
    tmp = dst + ".tmp"
    with open(tmp, "w") as f:
        f.write(conf)
    os.chmod(tmp, 0o600)
    os.replace(tmp, dst)

    print(f"[portal-ssid] primary='{cfg['PRIMARY_SSID']}' "
          f"baits={baits or '(none)'} pool={len(pool)}")

    if not no_restart:
        subprocess.run(["systemctl", "restart", "hostapd"], check=False)


if __name__ == "__main__":
    main()
