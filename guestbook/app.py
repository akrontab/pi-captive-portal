"""Minimal 90s-style guestbook: Flask + stdlib sqlite3, no ORM.

Served behind nginx at /guestbook (see config/nginx-portal.conf.tmpl), run by
gunicorn under systemd as www-data (see guestbook.service). The DB path and
limits are env-overridable so nothing is hardcoded to one deployment.
"""
import csv
import io
import json
import os
import re
import subprocess
import sqlite3
from datetime import datetime, timezone

from flask import (Flask, Response, abort, jsonify, redirect, render_template,
                   request)

DB_PATH     = os.environ.get("GUESTBOOK_DB", "/var/lib/portal/guestbook.db")
MAX_NAME    = int(os.environ.get("GUESTBOOK_MAX_NAME", "40"))
MAX_MESSAGE = int(os.environ.get("GUESTBOOK_MAX_MESSAGE", "500"))
SHOW_LIMIT  = int(os.environ.get("GUESTBOOK_SHOW_LIMIT", "200"))
LEASES      = os.environ.get("DNSMASQ_LEASES", "/var/lib/misc/dnsmasq.leases")
STATIONS    = os.environ.get("PORTAL_STATIONS", "/run/portal/stations.json")

app = Flask(__name__)
# Hostile-network hardening: cap request bodies so a client cannot flood us
# with a giant POST (names/messages are further length-capped in sign()).
app.config["MAX_CONTENT_LENGTH"] = int(
    os.environ.get("GUESTBOOK_MAX_BODY", str(64 * 1024)))

# ── Device fingerprinting ─────────────────────────────────────────────────────
# Everything here is observable on our own AP. See docs/metadata-capture.md.
# Sources degrade gracefully: any field we can't determine is recorded as null.

# Minimal built-in OUI → vendor map (best-effort; extend as needed). The raw
# OUI is always stored, so unknown vendors can be enriched later.
_OUI_VENDORS = {
    "b8:27:eb": "Raspberry Pi Foundation",
    "dc:a6:32": "Raspberry Pi Trading",
    "e4:5f:01": "Raspberry Pi Trading",
    "28:cd:c1": "Raspberry Pi Trading",
    "d8:3a:dd": "Raspberry Pi Trading",
    "00:0f:60": "Ralink/legacy",
    "3c:5a:b4": "Google",
    "f4:f5:e8": "Google",
    "ac:de:48": "Apple (private)",
    "dc:a9:04": "Apple",
    "a4:83:e7": "Apple",
    "f0:18:98": "Apple",
    "40:b0:76": "ASUSTek",
    "fc:aa:14": "GIGA-BYTE",
    "00:1a:11": "Google",
    "d0:37:45": "TP-Link",
    "50:c7:bf": "TP-Link",
    "8c:85:90": "Apple",
    "5c:cf:7f": "Espressif (ESP8266)",
    "24:0a:c4": "Espressif (ESP32)",
    "e8:db:84": "Espressif",
    "b4:e6:2d": "Espressif",
}


def _client_ip():
    return (request.headers.get("X-Real-IP")
            or (request.headers.get("X-Forwarded-For", "").split(",")[0].strip() or None)
            or request.remote_addr)


def _mac_from_neigh(ip):
    """IP -> MAC via the kernel neighbour (ARP) table. No root needed."""
    if not ip:
        return None
    for ip_bin in ("ip", "/usr/sbin/ip", "/sbin/ip", "/bin/ip"):
        try:
            out = subprocess.run([ip_bin, "neigh", "show", ip],
                                 capture_output=True, text=True, timeout=2).stdout
        except FileNotFoundError:
            continue
        except Exception:
            return None
        m = re.search(r"lladdr ([0-9a-f:]{17})", out)
        return m.group(1).lower() if m else None
    return None


def _lease_info(ip):
    """DHCP hostname + MAC from the dnsmasq lease file, if readable."""
    try:
        with open(LEASES) as f:
            for line in f:
                p = line.split()
                if len(p) >= 4 and p[2] == ip:
                    return {"mac": p[1].lower(),
                            "hostname": None if p[3] == "*" else p[3]}
    except Exception:
        pass
    return {}


def _station_info(mac):
    """Wi-Fi signal / session stats from the sidecar snapshot, keyed by MAC."""
    if not mac:
        return None
    try:
        with open(STATIONS) as f:
            return json.load(f).get(mac.lower())
    except Exception:
        return None


def _mac_randomized(mac):
    """True if the MAC is locally administered (iOS/Android private MAC)."""
    if not mac:
        return None
    try:
        return bool(int(mac.split(":")[0], 16) & 0x02)
    except Exception:
        return None


def _oui_vendor(mac):
    return _OUI_VENDORS.get(mac[:8].lower()) if mac else None


def _parse_ua(ua):
    ua_l = (ua or "").lower()
    os_ = next((n for p, n in (
        ("android", "Android"), ("iphone", "iOS"), ("ipad", "iPadOS"),
        ("windows", "Windows"), ("mac os", "macOS"), ("cros", "ChromeOS"),
        ("linux", "Linux")) if p in ua_l), None)
    br = next((n for p, n in (
        ("edg", "Edge"), ("opr", "Opera"), ("firefox", "Firefox"),
        ("chrome", "Chrome"), ("safari", "Safari")) if p in ua_l), None)
    return os_, br


def collect_metadata():
    """Everything we can learn about the poster's device, silently."""
    ip = _client_ip()
    mac = _mac_from_neigh(ip)
    lease = _lease_info(ip)
    if not mac:
        mac = lease.get("mac")
    ua = request.headers.get("User-Agent", "")
    ua_os, ua_browser = _parse_ua(ua)
    return {
        "ip":                 ip,
        "mac":                mac,
        "mac_vendor":         _oui_vendor(mac),
        "mac_randomized":     _mac_randomized(mac),
        "dhcp_hostname":      lease.get("hostname"),
        "user_agent":         ua or None,
        "ua_os":              ua_os,
        "ua_browser":         ua_browser,
        "accept_language":    request.headers.get("Accept-Language"),
        "accept":             request.headers.get("Accept"),
        "accept_encoding":    request.headers.get("Accept-Encoding"),
        "referer":            request.headers.get("Referer"),
        "sec_ch_ua":          request.headers.get("Sec-CH-UA"),
        "sec_ch_ua_platform": request.headers.get("Sec-CH-UA-Platform"),
        "sec_ch_ua_mobile":   request.headers.get("Sec-CH-UA-Mobile"),
        "dnt":                request.headers.get("DNT"),
        "wifi":               _station_info(mac),
    }


def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with get_db() as conn:
        # WAL: lets gunicorn's workers read while one writes.
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS entries (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                message    TEXT NOT NULL,
                created_at TEXT NOT NULL,
                meta       TEXT
            )
            """
        )
        # Migrate older DBs that predate the meta column.
        cols = [r[1] for r in conn.execute("PRAGMA table_info(entries)")]
        if "meta" not in cols:
            conn.execute("ALTER TABLE entries ADD COLUMN meta TEXT")


init_db()


@app.route("/guestbook")
def guestbook():
    with get_db() as conn:
        entries = conn.execute(
            "SELECT name, message, created_at FROM entries "
            "ORDER BY id DESC LIMIT ?",
            (SHOW_LIMIT,),
        ).fetchall()
        count = conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    # Jinja autoescapes name/message on render -> stored XSS is neutralised.
    return render_template("guestbook.html", entries=entries, count=count)


def _server_uptime_s():
    """Host uptime in whole seconds (Linux /proc/uptime); None off-Linux."""
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None


@app.route("/guestbook/entries")
def entries():
    """Public guestbook feed as JSON (no fingerprint meta), newest first.

    Backs the fetch()-driven guestbook on the restyled portal page. Also carries
    the host uptime so the page can show a live "server up" ticker without a
    second endpoint (the page ticks it client-side between fetches).
    """
    with get_db() as conn:
        rows = conn.execute(
            "SELECT id, name, message, created_at FROM entries "
            "ORDER BY id DESC LIMIT ?",
            (SHOW_LIMIT,),
        ).fetchall()
        count = conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    return jsonify({"count": count, "entries": [dict(r) for r in rows],
                    "server_uptime_s": _server_uptime_s()})


@app.route("/guestbook/sign", methods=["POST"])
def sign():
    # Accept either a form post (classic <form>) or a JSON body (fetch()).
    src = request.get_json(silent=True) if request.is_json else request.form
    src = src or {}
    name    = str(src.get("name") or "").strip()[:MAX_NAME]
    message = str(src.get("message") or "").strip()[:MAX_MESSAGE]
    wants_json = request.is_json or \
        "application/json" in request.headers.get("Accept", "")
    if not name or not message:
        if wants_json:
            return jsonify({"ok": False,
                            "error": "Name and message are both required."}), 400
        abort(400, "Name and message are both required.")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    try:
        meta = json.dumps(collect_metadata())
    except Exception:
        meta = None   # never let fingerprinting failure block a signing
    with get_db() as conn:  # parameterised -> no SQL injection
        cur = conn.execute(
            "INSERT INTO entries (name, message, created_at, meta) "
            "VALUES (?, ?, ?, ?)",
            (name, message, stamp, meta),
        )
        new_id = cur.lastrowid
    if wants_json:
        return jsonify({"ok": True,
                        "entry": {"id": new_id, "name": name,
                                  "message": message, "created_at": stamp}})
    return redirect("/guestbook")


def _csv_safe(v):
    """Neutralise CSV/formula injection: a cell starting with = + - @ (or a
    control char) can execute when the export is opened in Excel/Sheets.
    Attacker-controlled fields (name, message, hostname, UA) flow into the
    CSV, so prefix any such cell with a single quote."""
    if isinstance(v, str) and v[:1] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + v
    return v


@app.route("/guestbook/dump")
def dump():
    """Export every entry — JSON (default) or ?format=csv.

    No auth: reachable by anyone on the isolated portal network. Fine for this
    walled-garden LAN; do not expose it to an untrusted network.
    """
    with get_db() as conn:
        raw = conn.execute(
            "SELECT id, created_at, name, message, meta FROM entries ORDER BY id"
        ).fetchall()

    rows = []
    for r in raw:
        row = {"id": r["id"], "created_at": r["created_at"],
               "name": r["name"], "message": r["message"]}
        try:
            row["meta"] = json.loads(r["meta"]) if r["meta"] else None
        except Exception:
            row["meta"] = None
        rows.append(row)

    if request.args.get("format", "json").lower() == "csv":
        # Flatten the most useful fingerprint fields into columns.
        flat = ["ip", "mac", "mac_vendor", "mac_randomized", "dhcp_hostname",
                "ua_os", "ua_browser", "user_agent", "accept_language"]
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "created_at", "name", "message"] + flat + ["wifi_signal_dbm"])
        for r in rows:
            m = r["meta"] or {}
            wifi = (m.get("wifi") or {})
            w.writerow([_csv_safe(x) for x in (
                [r["id"], r["created_at"], r["name"], r["message"]]
                + [m.get(k) for k in flat]
                + [wifi.get("signal_dbm")]
            )])
        return Response(
            buf.getvalue(),
            mimetype="text/csv",
            headers={"Content-Disposition": "attachment; filename=guestbook.csv"},
        )
    return jsonify(rows)


if __name__ == "__main__":
    # Dev only; production runs under gunicorn.
    app.run(host="127.0.0.1", port=8080, debug=True)
