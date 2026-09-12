"""Minimal 90s-style guestbook: Flask + stdlib sqlite3, no ORM.

Served behind nginx at /guestbook (see config/nginx-portal.conf.tmpl), run by
gunicorn under systemd as www-data (see guestbook.service). The DB path and
limits are env-overridable so nothing is hardcoded to one deployment.
"""
import csv
import hmac
import io
import os
import sqlite3
from datetime import datetime, timezone

from flask import (Flask, Response, abort, jsonify, redirect, render_template,
                   request)

DB_PATH     = os.environ.get("GUESTBOOK_DB", "/var/lib/portal/guestbook.db")
MAX_NAME    = int(os.environ.get("GUESTBOOK_MAX_NAME", "40"))
MAX_MESSAGE = int(os.environ.get("GUESTBOOK_MAX_MESSAGE", "500"))
SHOW_LIMIT  = int(os.environ.get("GUESTBOOK_SHOW_LIMIT", "200"))
# Secret token for the /guestbook/dump endpoint. Empty = endpoint disabled.
DUMP_KEY    = os.environ.get("GUESTBOOK_DUMP_KEY", "")

app = Flask(__name__)


def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
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
                created_at TEXT NOT NULL
            )
            """
        )


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


@app.route("/guestbook/sign", methods=["POST"])
def sign():
    name    = (request.form.get("name") or "").strip()[:MAX_NAME]
    message = (request.form.get("message") or "").strip()[:MAX_MESSAGE]
    if not name or not message:
        abort(400, "Name and message are both required.")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    with get_db() as conn:  # parameterised -> no SQL injection
        conn.execute(
            "INSERT INTO entries (name, message, created_at) VALUES (?, ?, ?)",
            (name, message, stamp),
        )
    return redirect("/guestbook")


@app.route("/guestbook/dump")
def dump():
    """Secret export of every entry — JSON (default) or ?format=csv.

    Guarded by ?key=<GUESTBOOK_DUMP_KEY>. When no key is configured, or the key
    is wrong/missing, we 404 so the endpoint doesn't reveal that it exists.
    Note: on a plain-HTTP portal the key travels in the URL and lands in nginx
    logs — fine for an isolated LAN, not a real secret. Rotate via portal.env.
    """
    supplied = request.args.get("key", "")
    if not DUMP_KEY or not hmac.compare_digest(supplied, DUMP_KEY):
        abort(404)

    with get_db() as conn:
        rows = [dict(r) for r in conn.execute(
            "SELECT id, created_at, name, message FROM entries ORDER BY id"
        )]

    if request.args.get("format", "json").lower() == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "created_at", "name", "message"])
        for r in rows:
            w.writerow([r["id"], r["created_at"], r["name"], r["message"]])
        return Response(
            buf.getvalue(),
            mimetype="text/csv",
            headers={"Content-Disposition": "attachment; filename=guestbook.csv"},
        )
    return jsonify(rows)


if __name__ == "__main__":
    # Dev only; production runs under gunicorn.
    app.run(host="127.0.0.1", port=8080, debug=True)
