# Security hardening (hacker-conference threat model)

This portal is run at a hacker conference, so the **client network (`wlan0`) is
hostile**: assume attendees actively attack the guestbook app and the Pi itself.
Management happens over the **wired interface**, which is treated as trusted.

## Guestbook app (`guestbook/app.py`)
- **SQL injection:** every query is parameterised (`?` placeholders) — no string
  interpolation anywhere. This is the primary and sufficient SQLi defense; keep
  it that way when adding queries.
- **Stored XSS:** the restyled page renders entries with `textContent`, and the
  legacy `/guestbook` Jinja template autoescapes. Payloads are stored inert.
- **CSV / formula injection:** `/guestbook/dump?format=csv` prefixes any cell
  beginning with `= + - @` (or a control char) with `'`, so attacker-controlled
  fields (name, message, DHCP hostname, UA) can't execute when the export is
  opened in Excel/Sheets.
- **Flood/DoS:** `MAX_CONTENT_LENGTH` (64 KB, `GUESTBOOK_MAX_BODY`) rejects giant
  bodies; name/message are length-capped (40/500). SQLite runs in WAL with a
  `busy_timeout` so concurrent hammering waits instead of erroring.

## nginx (`config/nginx-portal.conf.tmpl` + `setup.sh`)
- `server_tokens off`; request-body cap; slowloris timeouts.
- Security headers: `X-Content-Type-Options`, `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`, and a tight **CSP** (`default-src 'none'`,
  same-origin `connect-src`, `data:` images). `'unsafe-inline'` is required for
  the page's inline script/style; `connect-src 'self'` blocks exfiltration.
- **Rate limiting** on `POST /guestbook/sign` (`limit_req`, 5 r/s, burst 10).
- **`/guestbook/dump` is restricted to localhost** (`allow 127.0.0.1; deny all`).
  The captured fingerprint DB (MACs, hostnames, UAs of every visitor) must not be
  scrapeable by attendees. Pull it yourself with `.\deploy.ps1 -PullGuestbook`
  (reads the DB over SSH) or an SSH tunnel — not over the client network.

## Host firewall (`setup.sh` `configure_firewall`)
Inbound on `wlan0` is locked to only what portal clients need:
- allow DHCP (`udp/67`), DNS (`udp/tcp 53`), HTTP (`tcp/80`);
- fast-fail HTTPS (`tcp/443` → REJECT with tcp-reset, so captive detection
  doesn't hang and we never MITM TLS);
- **drop everything else** — SSH (`22`), gunicorn (`8080`), and all other ports.

SSH/management stays reachable only over the **wired interface**, which is left
untouched. `ip_forward` stays `0` (nothing is routed off the portal).

## systemd sandbox (`guestbook/guestbook.service`)
Runs as `www-data` with `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full`
(+ `ReadWritePaths=/var/lib/portal`), `ProtectHome`, and kernel/cgroup/SUID
protections. `RestrictAddressFamilies` and `SystemCallFilter` are deliberately
NOT set — they'd break the `ip neigh` netlink call and the gunicorn socket.

## Recommended MANUAL steps (not auto-applied — your call)
These touch SSH/auth and can lock you out if done carelessly, so apply them by
hand after confirming wired key-auth works:
1. **sshd:** `PasswordAuthentication no`, `PermitRootLogin no`,
   `KbdInteractiveAuthentication no` in `/etc/ssh/sshd_config.d/` (key auth over
   the wired net is already set up). `sudo sshd -t` then reload.
2. Optionally bind `sshd` to the wired interface only (`ListenAddress <eth0 IP>`).
3. Optional **fail2ban** for the SSH jail (belt-and-suspenders; the firewall
   already hides SSH from `wlan0`).
4. Keep the OS patched: `sudo apt update && sudo apt full-upgrade` before the con.

## Verify after deploy
- `sudo nginx -t` and reload; `curl -I http://192.168.4.1/portal` shows the CSP.
- From a client, `curl http://192.168.4.1/guestbook/dump` → **403**; from the Pi,
  `curl http://127.0.0.1/guestbook/dump` → 200.
- `sudo iptables -L INPUT -n -v` shows the wlan0 allow/reject/drop chain.
- From a client, `nmap` the Pi → only 53/80 open, 443 reset, 22 filtered.
