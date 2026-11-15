# Faking a Linux uptime on Windows: a two-line monkeypatch

*Dev notes — how I tested the portal's new "server uptime" ticker without a Pi.*

## The feature

Someone wanted the portal to flex its uptime, 90s-server-style — a live
`↑ TH1S B0X HAS B33N UP 3d 04h 24m 39s` ticking away in the footer. Easy enough.
The portal page already talks to exactly one backend endpoint
(`GET /guestbook/entries`), and the design rule is "no backend calls except for
the guestbook," so instead of a new route I piggybacked the number onto that
response and let the browser tick it forward client-side:

```python
def _server_uptime_s():
    """Host uptime in whole seconds (Linux /proc/uptime); None off-Linux."""
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None
```

`/proc/uptime` is the kernel's own uptime clock — first field is seconds since
boot. Read it, floor it, ship it. On the Pi this Just Works.

## The problem

I develop on **Windows**. There is no `/proc/uptime` on Windows, so that `open()`
throws, the `except` swallows it, and the function politely returns `None`. That's
*correct* behavior — the page hides the ticker when the value is null — but it
also means I couldn't actually *see* the ticker while iterating locally. I wanted
to watch it render and count up in a real browser before shipping it to the Pi.

Options on the table:

- **Add a cross-platform uptime library** (e.g. `psutil.boot_time()`). Works, but
  it drags a dependency into a tiny app for the sake of one dev machine. No.
- **Fake a `/proc/uptime` file** and point the code at it via an env var. Doable,
  but now I'm changing production code paths to accommodate a test.
- **Monkeypatch the function in the test harness.** Zero changes to app code,
  two lines in the throwaway dev server. Winner.

## The workaround

My local test server imports the Flask app as a module and serves the page. The
whole fix is one line, dropped in right after the import:

```python
import importlib.util
spec = importlib.util.spec_from_file_location("gb", ".../guestbook/app.py")
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)

gb._server_uptime_s = lambda: 275079   # fake ~3d 4h uptime for dev

# ... serve index.html + the guestbook routes ...
gb.app.run(host="127.0.0.1", port=8099)
```

That's it. Now `GET /guestbook/entries` returns `"server_uptime_s": 275079`, the
page starts its client-side ticker from that baseline, and I can watch it climb
`...39s → 40s → 41s` in Chrome. Ship it.

## Sample test harness

Here's the whole throwaway dev server, fleshed out to something you can actually
run. Drop it at the repo root as `dev-server.py` and `python dev-server.py`. It's
Windows-friendly and never touches the Pi.

Two things it has to get right, both because `guestbook/app.py` does its work at
**import time**: it reads `GUESTBOOK_DB` from the environment when the module
loads, and it calls `init_db()` on the spot. So the fake DB path has to be set
*before* `exec_module`, and it needs a real parent directory (`init_db()` runs
`os.makedirs(os.path.dirname(DB_PATH))`, which blows up on a bare filename).

```python
#!/usr/bin/env python3
"""dev-server.py — run the guestbook app on Windows to eyeball the uptime ticker.

Not shipped to the Pi. Stands in for nginx + gunicorn: serves the portal page
and the guestbook routes on localhost, with _server_uptime_s() monkeypatched so
the footer ticker actually renders off-Linux (no /proc/uptime here).

    python dev-server.py      # then open http://127.0.0.1:8099/
"""
import importlib.util
import os
import tempfile
from pathlib import Path

REPO   = Path(__file__).resolve().parent
APP_PY = REPO / "guestbook" / "app.py"
INDEX  = REPO / "www" / "index.html"

# app.py reads GUESTBOOK_DB at import and calls init_db() immediately, so point
# it at a throwaway DB — with a real parent dir — BEFORE loading the module.
os.environ["GUESTBOOK_DB"] = str(Path(tempfile.gettempdir()) / "portal-dev" / "guestbook.db")

# Load guestbook/app.py as a module object we can reach into.
spec = importlib.util.spec_from_file_location("gb", APP_PY)
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)

# The whole point: fake a Linux uptime so the ticker has a baseline off-Linux.
# Rebinds the module-global name the route resolves at call time (see below).
gb._server_uptime_s = lambda: 275079            # ~3d 4h 24m 39s

# nginx serves the portal page in prod; here the dev server stands in for it so
# the page's fetch("/guestbook/entries") has a same-origin backend to hit.
# Added before the first request, so Flask's post-serve route lock never applies.
@gb.app.route("/")
def _dev_index():
    return INDEX.read_text(encoding="utf-8")

if __name__ == "__main__":
    # Seed a couple of entries so the feed isn't empty (optional, dev-only).
    with gb.get_db() as c:
        if c.execute("SELECT COUNT(*) FROM entries").fetchone()[0] == 0:
            c.executemany(
                "INSERT INTO entries (name, message, created_at) VALUES (?, ?, ?)",
                [("ac1d",   "first!!",      "2026-01-01T00:00:00"),
                 ("phr34k", "<3 this box",  "2026-01-01T00:01:00")])

    print(f"dev portal on http://127.0.0.1:8099/   (DB: {os.environ['GUESTBOOK_DB']}, uptime faked)")
    # use_reloader=False: the reloader re-execs this file, which would re-run the
    # import + monkeypatch in a child process — harmless here, but noise you don't
    # need while staring at a counter.
    gb.app.run(host="127.0.0.1", port=8099, use_reloader=False, debug=True)
```

Open `http://127.0.0.1:8099/`, and the footer ticks up from the faked baseline.
Want a different starting value? Change the one lambda — `lambda: 0` to watch it
count from boot, or point it at a real file (`lambda: int(float(open("uptime.txt")
.read()))`) if you'd rather drive it from outside the process. Nothing in
`app.py` changes either way.

To sanity-check just the JSON without a browser:

```console
$ curl -s http://127.0.0.1:8099/guestbook/entries | python -m json.tool
{
    "count": 2,
    "entries": [ ... ],
    "server_uptime_s": 275079
}
```

If `server_uptime_s` comes back `null`, the patch didn't take — you're hitting
the real `_server_uptime_s()` (usually because the rebind ran against a *different*
import of the module than the one Flask is serving; keep it to the single `gb`
object like above).

## Why this actually works (the Python bit)

The interesting part is *why* reassigning `gb._server_uptime_s` changes what the
route handler calls. The handler looks like this:

```python
@app.route("/guestbook/entries")
def entries():
    ...
    return jsonify({..., "server_uptime_s": _server_uptime_s()})
```

Notice it calls `_server_uptime_s()` **by name**. In Python, a bare-name function
call isn't bound at definition time — it's a lookup in the enclosing module's
namespace *at the moment the call runs*. So when I do `gb._server_uptime_s = ...`,
I'm rebinding that exact module-global name. The next time `entries()` executes,
it resolves `_server_uptime_s` to my lambda instead of the original. No import
tricks, no patching of call sites — just rebinding a name in a namespace, which is
all a module really is: a dict with a nice `__getattr__`.

Two things make it clean:

1. **The patch lives entirely in the dev harness**, never in `app.py`. Production
   code stays honest — it reads the real `/proc/uptime` and degrades to `None`
   off-Linux.
2. **The rebind happens before the first request.** Flask locks an app against
   *route* changes once it has served a request, but this isn't a route change —
   it's swapping a plain function the handler happens to call — so the "setup
   finished" guard never even applies. (Doing it up front is just tidy.)

## The takeaway

Monkeypatching gets a bad rap because people reach for it to paper over bad
design. But for a *test-only* substitution of a platform-specific dependency, it's
the least invasive tool there is: the production function stays pure, the fake
lives where the fakeness belongs, and Python's late-bound name resolution does all
the work. Two lines, one browser tab, one very smug little uptime counter.
