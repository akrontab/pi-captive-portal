#!/usr/bin/env python3
"""Passively log 802.11 probe requests seen on a monitor-mode radio.

Every Wi-Fi device that isn't connected periodically shouts "is <network> here?"
as a *probe request* — an unencrypted management frame carrying the device's MAC
and, often, the name of a network it's looking for. This daemon listens for those
frames on a dedicated monitor interface, channel-hops to cover the band, and
records into SQLite:

  * which devices are nearby (MAC, vendor, randomized-MAC flag, signal, counts)
  * which SSIDs each device is searching for (the "preferred network list" leaks)

Architecture (see docs/probe-logging.md): this needs its OWN radio. The portal's
AP radio can't also monitor (a radio does one channel at a time, and rt2800usb
won't do AP+monitor at all). The intended split once the AR9271 is the AP:
rt2800usb -> monitor (this daemon), AR9271 -> multi-BSS AP.

Capture is done by tcpdump (kernel BPF filters probe-requests efficiently); we
parse its pcap stream ourselves so we don't depend on tcpdump's text format.

Config: /etc/portal-probe.env (KEY=VALUE); real env vars override. Keys:
MONITOR_IF, PROBE_DB, PROBE_CHANNELS, PROBE_HOP, PROBE_HOP_INTERVAL,
PROBE_COMMIT_INTERVAL. Runs as root (monitor mode + channel set need it).

Flags: --report (print a summary from the DB and exit), --selftest (parse a
synthetic frame, no root/hardware needed).
"""
import os
import signal
import sqlite3
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

ENV_FILE = os.environ.get("PORTAL_PROBE_ENV", "/etc/portal-probe.env")
KEYS = ("MONITOR_IF", "PROBE_DB", "PROBE_CHANNELS", "PROBE_HOP",
        "PROBE_HOP_INTERVAL", "PROBE_COMMIT_INTERVAL")

# Tiny built-in OUI -> vendor map. Randomized MACs have no meaningful vendor, so
# this is just a courtesy for the (increasingly rare) devices that probe with
# their burned-in address. Extend as needed; not meant to be exhaustive.
OUI = {
    "3c:5a:b4": "Google", "f4:f5:e8": "Google",
    "dc:a6:32": "Raspberry Pi", "b8:27:eb": "Raspberry Pi",
    "00:1a:11": "Google", "3c:07:54": "Apple", "a4:83:e7": "Apple",
    "ac:de:48": "Apple", "f0:18:98": "Apple", "d0:03:4b": "Apple",
    "8c:85:90": "Apple", "fc:fc:48": "Apple",
    "5c:51:4f": "Intel", "34:41:5d": "Intel", "00:16:6c": "Samsung",
    "8c:77:12": "Samsung", "fe:dc:ba": "(locally-administered)",
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    cfg.setdefault("MONITOR_IF", "wlan1")
    cfg.setdefault("PROBE_DB", "/var/lib/portal/probes.db")
    cfg.setdefault("PROBE_CHANNELS", "1,6,11")
    cfg.setdefault("PROBE_HOP", "1")
    cfg.setdefault("PROBE_HOP_INTERVAL", "0.5")
    cfg.setdefault("PROBE_COMMIT_INTERVAL", "5")
    return cfg


# ── frame parsing ─────────────────────────────────────────────────────────────

def _radiotap_signal(pkt):
    """Best-effort dBm antenna-signal out of a radiotap header. None if absent.

    Radiotap is a variable header: a bitmap of 'present' fields, then the fields
    themselves in bit order, each aligned to its own size. We walk the fields up
    to bit 5 (dBm antenna signal) respecting alignment, and read that one byte."""
    if len(pkt) < 8:
        return None
    _ver, _pad, rlen = struct.unpack_from("<BBH", pkt, 0)
    # Collect present-flags words (bit 31 chains another word).
    off = 4
    present = []
    while off + 4 <= len(pkt):
        (word,) = struct.unpack_from("<I", pkt, off)
        present.append(word)
        off += 4
        if not (word & (1 << 31)):
            break
    else:
        return None
    first = present[0]
    # (bit, size, alignment) for the standard leading fields.
    fields = [(0, 8, 8), (1, 1, 1), (2, 1, 1), (3, 4, 2), (4, 2, 2), (5, 1, 1)]
    pos = off                            # fields start right after present words
    for bit, size, align in fields:
        if not (first & (1 << bit)):
            continue
        if pos % align:
            pos += align - (pos % align)
        if bit == 5:                     # dBm antenna signal, signed
            if pos < len(pkt):
                return struct.unpack_from("<b", pkt, pos)[0]
            return None
        pos += size
    return None


def _first_ssid(pkt, off):
    """SSID from the first (tag 0) element of a mgmt frame body. '' = wildcard."""
    n = len(pkt)
    while off + 2 <= n:
        tid, tlen = pkt[off], pkt[off + 1]
        val = pkt[off + 2:off + 2 + tlen]
        if tid == 0:
            return val.decode("utf-8", "replace")
        off += 2 + tlen
    return ""


def parse_probe(pkt):
    """radiotap+802.11 bytes -> dict for a probe request, or None if not one."""
    if len(pkt) < 4:
        return None
    rlen = struct.unpack_from("<H", pkt, 2)[0]
    if rlen < 8 or rlen + 24 > len(pkt):
        return None
    fc0 = pkt[rlen]
    if (fc0 & 0x0C) != 0x00 or (fc0 & 0xF0) != 0x40:   # not mgmt/probe-req
        return None
    src = pkt[rlen + 10:rlen + 16]                       # addr2 = transmitter
    if len(src) < 6:
        return None
    mac = ":".join("%02x" % b for b in src)
    randomized = 1 if (src[0] & 0x02) else 0
    vendor = None if randomized else OUI.get(mac[:8])
    return {
        "mac": mac,
        "randomized": randomized,
        "vendor": vendor,
        "ssid": _first_ssid(pkt, rlen + 24),
        "signal": _radiotap_signal(pkt),
    }


# ── pcap stream ───────────────────────────────────────────────────────────────

def _read_exactly(stream, n):
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def pcap_frames(stream):
    """Yield raw packet bytes from a classic-pcap stream on `stream` (binary)."""
    hdr = _read_exactly(stream, 24)
    if not hdr or len(hdr) < 24:
        return
    magic = hdr[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"                     # little-endian writer (the Pi)
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        return                           # not a pcap stream we understand
    rechdr = endian + "IIII"
    while True:
        rec = _read_exactly(stream, 16)
        if not rec:
            return
        _s, _u, incl, _orig = struct.unpack(rechdr, rec)
        if incl == 0:
            continue
        data = _read_exactly(stream, incl)
        if data is None:
            return
        yield data


# ── storage ───────────────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
  mac         TEXT PRIMARY KEY,
  vendor      TEXT,
  randomized  INTEGER,
  first_seen  TEXT,
  last_seen   TEXT,
  count       INTEGER,
  last_signal INTEGER
);
CREATE TABLE IF NOT EXISTS probes (
  mac        TEXT,
  ssid       TEXT,
  first_seen TEXT,
  last_seen  TEXT,
  count      INTEGER,
  PRIMARY KEY (mac, ssid)
);
"""


def open_db(path):
    if path != ":memory:":
        os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    db.executescript(SCHEMA)
    return db


def record(db, p, ts):
    db.execute(
        """INSERT INTO devices (mac, vendor, randomized, first_seen, last_seen,
                                count, last_signal)
           VALUES (?,?,?,?,?,1,?)
           ON CONFLICT(mac) DO UPDATE SET
             last_seen=excluded.last_seen,
             count=count+1,
             last_signal=COALESCE(excluded.last_signal, last_signal),
             vendor=COALESCE(devices.vendor, excluded.vendor)""",
        (p["mac"], p["vendor"], p["randomized"], ts, ts, p["signal"]))
    db.execute(
        """INSERT INTO probes (mac, ssid, first_seen, last_seen, count)
           VALUES (?,?,?,?,1)
           ON CONFLICT(mac, ssid) DO UPDATE SET
             last_seen=excluded.last_seen, count=count+1""",
        (p["mac"], p["ssid"], ts, ts))


# ── radio control ─────────────────────────────────────────────────────────────

def _run(cmd):
    return subprocess.run(cmd, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def ensure_monitor(mon):
    """Put `mon` into monitor mode and up. Best-effort; logs what it did."""
    _run(["ip", "link", "set", mon, "down"])
    ok = _run(["iw", "dev", mon, "set", "type", "monitor"])
    up = _run(["ip", "link", "set", mon, "up"])
    print(f"[probe] {mon}: monitor={'ok' if ok else 'FAILED'} up={'ok' if up else 'FAILED'}",
          flush=True)
    return up


def channel_hopper(mon, channels, interval, stop):
    if len(channels) <= 1:
        return
    while not stop.is_set():
        for ch in channels:
            if stop.is_set():
                break
            _run(["iw", "dev", mon, "set", "channel", str(ch)])
            stop.wait(interval)


# ── main loop ─────────────────────────────────────────────────────────────────

def capture(cfg, stop):
    mon = cfg["MONITOR_IF"]
    channels = [c.strip() for c in cfg["PROBE_CHANNELS"].split(",") if c.strip()]
    hop = cfg["PROBE_HOP"] == "1" and len(channels) > 1
    commit_every = float(cfg["PROBE_COMMIT_INTERVAL"])

    db = open_db(cfg["PROBE_DB"])
    ensure_monitor(mon)

    hopper = None
    if hop:
        hopper = threading.Thread(target=channel_hopper,
                                  args=(mon, channels, float(cfg["PROBE_HOP_INTERVAL"]), stop),
                                  daemon=True)
        hopper.start()

    td = subprocess.Popen(
        ["tcpdump", "-i", mon, "-w", "-", "-U", "-s", "256",
         "type", "mgt", "subtype", "probe-req"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    print(f"[probe] listening on {mon} channels={channels or 'current'} "
          f"hop={'on' if hop else 'off'} db={cfg['PROBE_DB']}", flush=True)

    seen = 0
    last_commit = time.time()
    try:
        for pkt in pcap_frames(td.stdout):
            if stop.is_set():
                break
            p = parse_probe(pkt)
            if not p:
                continue
            record(db, p, now_iso())
            seen += 1
            if time.time() - last_commit >= commit_every:
                db.commit()
                last_commit = time.time()
    finally:
        db.commit()
        stop.set()
        try:
            td.terminate()
        except Exception:
            pass
        db.close()
        print(f"[probe] stopped; {seen} probe frames recorded this run", flush=True)


def report(cfg):
    db = open_db(cfg["PROBE_DB"])
    dev = db.execute("SELECT COUNT(*), COALESCE(SUM(randomized),0) FROM devices").fetchone()
    total, rnd = dev[0], dev[1]
    print(f"Devices seen: {total}  (randomized MAC: {rnd}, "
          f"{100*rnd//total if total else 0}%)")
    print("\nTop SSIDs devices are searching for (by distinct devices):")
    rows = db.execute(
        """SELECT ssid, COUNT(DISTINCT mac) d, SUM(count) c FROM probes
           WHERE ssid <> '' GROUP BY ssid ORDER BY d DESC, c DESC LIMIT 20"""
    ).fetchall()
    for ssid, d, c in rows:
        print(f"  {d:4d} devices  {c:6d} probes  {ssid}")
    wildcard = db.execute("SELECT COALESCE(SUM(count),0) FROM probes WHERE ssid=''").fetchone()[0]
    print(f"\nBroadcast/wildcard probes (no SSID): {wildcard}")
    print("\nMost recently seen devices:")
    for mac, v, r, sig, ls in db.execute(
        """SELECT mac, vendor, randomized, last_signal, last_seen FROM devices
           ORDER BY last_seen DESC LIMIT 15"""):
        tag = "(random)" if r else (v or "?")
        print(f"  {mac}  {str(sig)+' dBm':>9}  {ls}  {tag}")
    db.close()


def selftest():
    """Parse a hand-built radiotap+probe-req frame; no root or hardware needed."""
    # radiotap: v0, pad0, len=9, present=(1<<5) [dBm signal], signal=0xd6 (-42)
    rt = struct.pack("<BBHI b", 0, 0, 9, (1 << 5), -42)
    # 802.11 probe-req: FC=0x40,0x00 dur=0 addr1=bcast addr2=3c:5a:b4:11:22:33
    #                   addr3=bcast seq=0 ; body: SSID tag "TestNet"
    dot11 = bytes([0x40, 0x00, 0x00, 0x00]) + b"\xff" * 6 \
        + bytes([0x3c, 0x5a, 0xb4, 0x11, 0x22, 0x33]) + b"\xff" * 6 \
        + bytes([0x00, 0x00]) \
        + bytes([0x00, len("TestNet")]) + b"TestNet"
    p = parse_probe(rt + dot11)
    assert p is not None, "frame not recognized as probe-req"
    assert p["mac"] == "3c:5a:b4:11:22:33", p["mac"]
    assert p["ssid"] == "TestNet", repr(p["ssid"])
    assert p["randomized"] == 0, p["randomized"]
    assert p["vendor"] == "Google", p["vendor"]
    assert p["signal"] == -42, p["signal"]
    # randomized MAC (locally-administered bit) + wildcard SSID
    rnd = bytes([0x40, 0x00, 0x00, 0x00]) + b"\xff" * 6 \
        + bytes([0xda, 0xad, 0xbe, 0xef, 0x00, 0x01]) + b"\xff" * 6 \
        + bytes([0x00, 0x00]) + bytes([0x00, 0x00])
    q = parse_probe(rt + rnd)
    assert q["randomized"] == 1 and q["ssid"] == "" and q["vendor"] is None, q
    # storage round-trip in memory
    db = open_db(":memory:")
    record(db, p, now_iso())
    record(db, p, now_iso())
    assert db.execute("SELECT count FROM devices WHERE mac=?", (p["mac"],)).fetchone()[0] == 2
    db.close()
    print("selftest OK")


def main():
    args = sys.argv[1:]
    if "--selftest" in args:
        selftest()
        return
    cfg = load_config()
    if "--report" in args:
        report(cfg)
        return
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    capture(cfg, stop)


if __name__ == "__main__":
    main()
