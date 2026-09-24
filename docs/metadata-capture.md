# Guestbook metadata capture — design spec (DROPPED)

> **DROPPED (2026-09-24) — no further work.** Device fingerprinting is off the
> roadmap by decision. None of the deferred layers below (DHCP-option
> fingerprinting, probe correlation, p0f, a full OUI table, `Accept-CH`) will be
> built. The already-shipped v1 collector (`collect_metadata()` in
> `guestbook/app.py` + the `portal-stations` sidecar) remains deployed for now and
> was **not** ripped out — remove it separately if/when desired. This spec is kept
> only as a record of intent.

Goal: alongside each guestbook post, silently record as much identifying /
fingerprinting information about the poster's device as the captive AP can see,
without asking them to type anything. This is a walled-garden AP we own; all
data below is already observable on our own hardware.

Status: **v1 implemented** (in `guestbook/app.py` + `guestbook/portal-stations.*`).
Live: HTTP layer (A), IP→MAC via `ip neigh` + dnsmasq leases, vendor/randomized-MAC,
DHCP hostname (B), and Wi-Fi station stats via the sidecar (C). Stored as a JSON
blob in `entries.meta`; surfaced in `/guestbook/dump` (nested JSON; flattened CSV).
Deferred: DHCP option fingerprinting (D), probe correlation (E), p0f (F), and a
full OUI table (only a small built-in vendor map so far).

> Light-touch note (your call): a one-line "connections on this network are
> logged" on the form is good practice. Not required for it to work.

---

## What's capturable, by layer

### A. HTTP request — free, no privilege (Flask `request`)
Grabbed directly in the POST handler:

| Field                               | Source                          | Notes                                  |
| ----------------------------------- | ------------------------------- | -------------------------------------- |
| User-Agent                          | `request.headers['User-Agent']` | Parse → OS, browser, device family     |
| Accept-Language                     | header                          | Language/locale preference             |
| Accept, Accept-Encoding             | headers                         | Capability fingerprint                 |
| Referer                             | header                          | Usually the portal page                |
| Client IP                           | `request.headers['X-Real-IP']`  | nginx already sets it (see nginx tmpl) |
| Sec-CH-UA*, platform, mobile, model | Client Hints                    | Chromium only; see caveat below        |
| DNT                                 | header                          | Rarely useful, cheap to keep           |
| Raw header dump                     | `dict(request.headers)`         | Store as JSON for later mining         |

**Client Hints caveat:** high-entropy hints (platform-version, model,
full-version) are only sent by Chromium browsers, only after the server asks via
an `Accept-CH` response header, and in most browsers only over **HTTPS**. Our
portal is HTTP-only, so expect little beyond the low-entropy `Sec-CH-UA`,
`Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform`. Add `Accept-CH` in nginx anyway; take
what we get.

### B. Network layer — correlate the poster's IP → MAC
**MAC is not in the HTTP request.** Get it by matching the client IP against the
Pi's own tables:

| Field               | Source                                                  | Notes                                                                              |
| ------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| MAC address         | `/var/lib/misc/dnsmasq.leases` or `ip neigh show <ip>`  | The key join                                                                       |
| DHCP hostname       | dnsmasq leases (col 4)                                  | Device's self-reported name, e.g. `Aarons-iPhone` — often the richest single field |
| Lease start/expiry  | dnsmasq leases                                          | When they joined                                                                   |
| Vendor (OUI)        | first 3 MAC octets → vendor table                       | Apple / Samsung / etc.                                                             |
| Randomized-MAC flag | 2nd hex digit of MAC ∈ {2,6,A,E} = locally administered | iOS/Android private-MAC privacy feature; flags a device deliberately hiding        |

`dnsmasq.leases` format: `<expiry_epoch> <mac> <ip> <hostname> <client-id>`.

### C. Wi-Fi / radio layer — needs privilege (`iw`)
From hostapd's associated-station table, keyed by MAC:

| Field                  | Source                      | Notes                   |
| ---------------------- | --------------------------- | ----------------------- |
| Signal strength (dBm)  | `iw dev wlan0 station dump` | Rough proximity         |
| Connected time         | same                        | How long associated     |
| TX/RX bytes & packets  | same                        | Activity volume         |
| Negotiated rate / caps | same                        | Device capability hints |

`iw ... station dump` needs root. **Do not give the web app root.** Use a
sidecar (systemd timer, every ~10s) that writes a world-readable snapshot
(`/run/portal/stations.json`, `/run/portal/leases.json`) which the Flask app
reads. Keeps privilege out of the request path and stays pluggable.

### D. DHCP fingerprinting — dnsmasq logs
dnsmasq already has `log-dhcp` on. Parseable from the journal:

| Field                          | Source                | Notes                              |
| ------------------------------ | --------------------- | ---------------------------------- |
| Option 55 (param request list) | DHCP DISCOVER/REQUEST | Fingerbank-style OS fingerprint    |
| Option 60 (vendor class)       | DHCP                  | e.g. `android-dhcp-14`, `MSFT 5.0` |
| Option 12 (hostname)           | DHCP                  | Same as lease hostname             |

### E. Captive-portal probe correlation — dnsmasq query log
Which OS probe host the device hit first confirms platform:
`captive.apple.com` → Apple, `connectivitycheck.gstatic.com` → Android,
`www.msftconnecttest.com` → Windows, `detectportal.firefox.com` → Firefox.
Correlate by client IP + timestamp near the post.

### F. Passive TCP/IP fingerprinting — optional, heavier
`p0f` on `wlan0` → OS guess, uptime, network distance from SYN packets. Only if
we want more than the above justifies. Extra daemon; likely overkill for a PoC.

### Not applicable
Geolocation / IP intel — no internet upstream, RFC1918 only. TLS/JA3 — 443 is
rejected, no TLS to fingerprint.

---

## Storage

Keep the guestbook table clean; put metadata in its own place so it stays
optional/swappable and a redeploy of the app never forces a schema fight.

Option 1 (simplest): add a `meta TEXT` JSON column to `entries`.
Option 2 (cleaner): separate `entry_meta(entry_id, key, value)` or
`entry_meta(entry_id, json)` 1:1 table.

Recommend **Option 1** for the PoC (one JSON blob = every field above, easy to
extend without migrations), revisit if we ever want to query on a field.

---

## Implementation sketch (when we build it)

1. `collect_metadata(request)` in `app.py` — gathers layer A synchronously.
2. Read `/run/portal/leases.json` + `/run/portal/stations.json` snapshots,
   join on client IP → MAC → station stats (layers B, C).
3. OUI vendor lookup from a small bundled prefix file (trimmed IEEE OUI list) —
   avoids a network call and a heavy dep.
4. Randomized-MAC + vendor + UA-derived OS/browser as computed fields.
5. Write it all as one JSON blob into `entries.meta` at insert time.
6. Sidecar: `portal-snapshot.timer`/`.service` (root) dumping
   `iw station dump` and the lease file to `/run/portal/*.json`, 0644.
7. nginx: add `Accept-CH` header to opportunistically request client hints.
8. Extend `-PullGuestbook` CSV and the `/guestbook/dump` endpoint to flatten the
   common meta fields into columns / JSON keys.

## Dependencies to weigh (keep lightweight)
- UA parsing: prefer a few regexes or a tiny lib over `ua-parser` if it pulls
  much in. Client Hints reduce the need.
- OUI list: ship a trimmed CSV, not a live lookup.
- No root in the web app — the sidecar owns all privileged reads.
