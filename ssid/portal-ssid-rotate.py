#!/usr/bin/env python3
"""Render hostapd's live config from a base file + a bait-SSID selection.

The primary SSID (the stable "Portal") lives in the base config as the first
BSS. This script appends up to SSID_BAIT_COUNT extra `bss=` stanzas — chosen at
random from a pool file — and (unless --no-restart) restarts hostapd so the new
bait set goes live. Run periodically by portal-ssid-rotate.timer to reshuffle.

Config comes from /etc/portal-ssid.env (KEY=VALUE); real environment variables
override it. Keys: WLAN_IF, SSID_POOL_FILE, SSID_BAIT_COUNT, PRIMARY_SSID,
HOSTAPD_BASE, HOSTAPD_CONF. All privileged work runs as root from the timer.

Flags: --no-restart (render the conf but don't bounce hostapd), --cleanup-only
(just delete leftover <iface>_N bait VIFs and exit; used as hostapd ExecStartPre).
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


def _secondary_ifaces(iface):
    """Existing hostapd-created secondary VIFs for this radio: <iface>_0, _1 …

    hostapd names extra BSSes `<iface>_N`; it creates them on start but never
    deletes them on stop, so they pile up across restarts (ifindex climbs into
    the thousands on a long-lived Pi). Match by the `<iface>_<digits>` shape."""
    import re
    pat = re.compile(rf"^{re.escape(iface)}_\d+$")
    try:
        return sorted(n for n in os.listdir("/sys/class/net") if pat.match(n))
    except OSError:
        return []


def cleanup_secondaries(iface):
    """Delete leftover `<iface>_N` VIFs so a hostapd (re)start builds them fresh.

    Runs before every restart in the rotate path; hostapd also gets an
    ExecStartPre calling `--cleanup-only` (see setup.sh) so cold starts that
    don't go through this script are covered too."""
    removed = []
    for name in _secondary_ifaces(iface):
        r = subprocess.run(["iw", "dev", name, "del"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            removed.append(name)
    if removed:
        print(f"[portal-ssid] removed orphan VIFs: {', '.join(removed)}")
    return removed


def _iface_mac(iface):
    try:
        with open(f"/sys/class/net/{iface}/address") as f:
            return f.read().strip().lower()
    except Exception:
        return None


def _bssid_block(mac, n):
    """Explicit, block-aligned, locally-administered BSSIDs for 1 primary + n
    baits. hostapd derives a BSSID mask across all BSSes and requires the
    lowest (primary) address to be block-aligned (addr AND mask == addr); the
    card's burned-in MAC usually isn't, which makes multi-BSS fail. So we hand
    out our own: set the locally-administered bit, clear the low nibble of the
    last octet for the block base, then increment for each bait."""
    if not mac or mac.count(":") != 5:
        return None, []
    try:
        b = [int(x, 16) for x in mac.split(":")]
    except ValueError:
        return None, []
    b[0] = (b[0] & 0xfe) | 0x02      # locally administered, unicast
    b[5] = b[5] & 0xf0               # 16-address block base (fits primary + 15)
    fmt = lambda v: ":".join("%02x" % x for x in v)
    primary = fmt(b)
    baits = []
    for i in range(n):
        c = b[:]
        c[5] = (b[5] + i + 1) & 0xff
        baits.append(fmt(c))
    return primary, baits


def build_conf(base_text, iface, baits):
    base = base_text.rstrip("\n")
    if not baits:
        return base + "\n"          # single SSID -> no multi-BSS, no mask

    primary_bssid, bait_bssids = _bssid_block(_iface_mac(iface), len(baits))
    if primary_bssid:
        # Primary advertises the block-base BSSID so hostapd's mask check
        # passes (only inject if the base config has no bssid already).
        lines = base.split("\n")
        if not any(l.strip().startswith("bssid=") for l in lines):
            out = []
            for l in lines:
                out.append(l)
                if l.strip().startswith("interface="):
                    out.append("bssid=" + primary_bssid)
            base = "\n".join(out)

    parts = [base, ""]
    for i, name in enumerate(baits):
        parts += [f"bss={iface}_{i}", f"ssid={name}"]
        if i < len(bait_bssids):
            parts.append(f"bssid={bait_bssids[i]}")
        parts += ["ignore_broadcast_ssid=0", ""]
    return "\n".join(parts) + "\n"


def main():
    args = sys.argv[1:]
    no_restart = "--no-restart" in args
    cfg = load_config()

    # ExecStartPre hook: just reap orphan VIFs, don't touch the config.
    if "--cleanup-only" in args:
        cleanup_secondaries(cfg["WLAN_IF"])
        return

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
        # Reap the old BSS VIFs first; hostapd rebuilds them from the new conf.
        cleanup_secondaries(cfg["WLAN_IF"])
        subprocess.run(["systemctl", "restart", "hostapd"], check=False)


if __name__ == "__main__":
    main()
