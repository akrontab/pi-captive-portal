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
- **`/guestbook/dump` is reachable from localhost and the portal subnet**
  (`allow 127.0.0.1; allow ::1; allow <portal>/24; deny all` — the subnet is
  derived from `PORTAL_IP`/`PREFIX` in `setup.sh`). ⚠️ **Trade-off, chosen
  deliberately:** this lets any client on the portal Wi-Fi scrape the captured
  fingerprint DB (MACs, hostnames, UAs of every visitor). It is *not* the
  hardened default — at a hostile event, narrow the `allow` back to
  `127.0.0.1`/`::1` in `configure_nginx` and pull the data yourself with
  `.\deploy.ps1 -PullJson` / `-PullGuestbook` (over SSH) instead.

## Host firewall (`setup.sh` `configure_firewall`)
Inbound on `wlan0` is locked to only what portal clients need:
- allow DHCP (`udp/67`), DNS (`udp/tcp 53`), HTTP (`tcp/80`);
- fast-fail HTTPS (`tcp/443` → REJECT with tcp-reset, so captive detection
  doesn't hang and we never MITM TLS);
- **drop everything else** — SSH (`22`), gunicorn (`8080`), and all other ports.

**IPv6 counts too.** The IPv4 rules above do nothing for IPv6, and sshd listens
on both. systemd-networkd would otherwise give `wlan0` an `fe80::` link-local
address, so a portal client could reach port 22 over v6 and walk straight past
the v4 firewall. Two defences, both in `setup.sh` / the `.network` template:
- `LinkLocalAddressing=no` + `IPv6AcceptRA=no` on the AP radio — the portal is
  IPv4-only, so the interface gets no v6 address at all;
- an `ip6tables` ruleset (`/etc/iptables/rules.v6`) mirroring the v4 policy:
  allow loopback/return/ICMPv6/DHCPv6/DNS/HTTP, **drop the rest incl. `22`**.

The full walk-through of the bypass, with a lite PoC, is in
[`ipv6-sshd-bypass.md`](ipv6-sshd-bypass.md).

SSH/management stays reachable only over the **wired interface**, which is left
untouched. `ip_forward` (v4 and v6) stays `0` (nothing is routed off the portal).

## Least privilege: who runs as what
Goal: keep root out of everything that doesn't strictly need it. Each service
has its own locked system account (no shell, no home) so a compromise of one
can't read or change another's files. All code under `/opt` is root-owned and
read-only to the services that run it.

| Service | Runs as | Capabilities | Writable |
|---|---|---|---|
| nginx workers | `www-data` | none | nothing (`/var/www/portal` is root-owned) |
| `guestbook` (gunicorn) | `guestbook` | none | `/var/lib/portal` only |
| `portal-stations` (10s timer) | `portal-stations` | `CAP_NET_ADMIN` | `/run/portal` only |
| `portal-health` (60s timer) | `portal-health` (+`video` for `vcgencmd`) | none | `/run/portal-health` only |
| `portal-probe-logger` | `portal-probe` | `CAP_NET_ADMIN`, `CAP_NET_RAW` | `/var/lib/portal-probe` only |
| `portal-ssid-rotate` | root (uid 0) | `CAP_NET_ADMIN` only | `/etc/hostapd` only |
| hostapd, dnsmasq, nginx master | root (distro units) | distro defaults | distro defaults |

Every custom unit also sets `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`,
`ProtectSystem=strict`, and kernel/cgroup/SUID protections.

**Why this layout.** Previously the guestbook ran as `www-data`, owned
`/opt/guestbook`, and that folder also held `portal-stations.py`, which ran
**as root** every 10s. Code execution in the guestbook could rewrite that script
and become root within seconds. Now the app can't write its own code, and the
sidecar lives root-owned at `/opt/portal-stations.py` with only one capability.

**SSID rotator stays uid 0** because it rewrites the root-owned hostapd config
and asks PID 1 to restart hostapd. Its capability bounding set is cut to
`CAP_NET_ADMIN` (for `iw dev … del`), so even as uid 0 it can't override file
permissions, load modules, or change ownership.

**Operator reads run as the service, not root.** `deploy.ps1`'s guestbook/probe
exports and purge run `sudo -u guestbook` / `sudo -u portal-probe`, and the
probe report is `sudo -u portal-probe python3 /opt/portal-probe-logger.py
--report`. Running SQLite as root could leave root-owned `-wal`/`-shm` (or a
fresh root-owned DB) that the service then can't write.

`RestrictAddressFamilies` and `SystemCallFilter` are deliberately NOT set on the
guestbook — they'd break the `ip neigh` netlink call and the gunicorn socket.

## SSH & sudo (management plane)
Management is over the **wired** interface only — the host firewall hides `22`
from `wlan0`, so attendees on the client network can't reach either of these.

- **Key-only SSH.** Password login is disabled:
  `/etc/ssh/sshd_config.d/10-no-passwords.conf` sets `PasswordAuthentication no`
  (`KbdInteractiveAuthentication no` is set in the base config). Only
  `~/.ssh/pi-captive-portal` gets you in — keep a copy; a lost key means recovery
  from the console.
- **Passwordless sudo** for `pi` (`/etc/sudoers.d/011_pi-nopasswd`,
  `pi ALL=(ALL) NOPASSWD: ALL`). Deliberate: `deploy.ps1` runs `sudo` over a
  non-interactive SSH session that can't answer a password prompt. It widens
  nothing an attacker would gain anyway — `pi` already has full sudo, and sudo is
  only reachable *behind* key-only SSH on the wired net. The password we removed
  was a second gate behind a gate only the key-holder can open. Set it up with the
  one-liner in the README's *Pi prerequisites*.

## Recommended MANUAL steps (not auto-applied — your call)
These touch SSH/auth and can lock you out if done carelessly, so apply them by
hand after confirming wired key-auth works:
1. **sshd:** `PasswordAuthentication no` and `KbdInteractiveAuthentication no` are
   already in place (see above); still worth adding **`PermitRootLogin no`** in
   `/etc/ssh/sshd_config.d/`. `sudo sshd -t` then reload.
2. Optionally bind `sshd` to the wired interface only (`ListenAddress <eth0 IP>`).
3. Optional **fail2ban** for the SSH jail (belt-and-suspenders; the firewall
   already hides SSH from `wlan0`).
4. Keep the OS patched: `sudo apt update && sudo apt full-upgrade` before the con.

## Verify after deploy
- `sudo nginx -t` and reload; `curl -I http://192.168.4.1/portal` shows the CSP.
- `curl http://127.0.0.1/guestbook/dump` on the Pi → **200**. From a portal
  client, `curl http://192.168.4.1/guestbook/dump` → **200** as well (the subnet
  is allowed); it returns **403** only if you've narrowed the rule back to
  localhost.
- `sudo iptables -L INPUT -n -v` shows the wlan0 allow/reject/drop chain.
- From a client, `nmap` the Pi → only 53/80 open, 443 reset, 22 filtered.
