# pi-captive-portal

Isolated Wi-Fi AP on a Raspberry Pi 3 that serves one local page to every
client — a walled garden, no internet upstream. hostapd + dnsmasq + nginx.

Full annotated walkthrough of every step lives in
[`pi3-captive-portal.md`](pi3-captive-portal.md). This README is the scripted path.

## Layout

| Path | What it is |
|---|---|
| `portal.env.example` | All tunables (SSID, IP, channel, WPA…). Copy to `portal.env`. |
| `deploy.ps1` | **Windows** driver — scp files to the Pi, run `setup.sh` over SSH. |
| `setup.sh` | Runs **on the Pi** as root. Idempotent. `install` / `rollback`. |
| `config/*.tmpl` | hostapd, dnsmasq, networkd, nginx — `@TOKEN@` rendered from `portal.env`. |
| `www/index.html` | The served portal page (single self-contained file). |

`portal.env` is the single source of truth: the IP set there is rendered into
every config file, so nothing drifts and each piece stays swappable.

## Finding the Pi

Don't know the Pi's address? `find-pi.ps1` locates it:

```powershell
.\find-pi.ps1                # prints candidates + a best guess
$pi = .\find-pi.ps1 -Quiet   # just the IP, for scripting:  ssh "pi@$pi"
```

How it works, best-first:

1. **mDNS** — resolves `raspberrypi.local` / `pi.local` (`-Names` to add more).
   Works when the Pi's `avahi` is up; gives you the host with no scanning.
2. **Subnet sweep** — finds your local IPv4 that has a default gateway, then
   async-pings every host in that `/24`. It doesn't need the replies; the point
   is that each ping forces your OS to ARP for the address, filling the ARP
   cache. Async (`.NET SendPingAsync`) so all 254 go out at once — a second or
   two, not minutes.
3. **ARP match** — reads the now-warm `arp -a` cache and flags any MAC whose
   first three octets (the OUI) belong to Raspberry Pi (`b8:27:eb`, `dc:a6:32`,
   `e4:5f:01`, …). That's how it finds a Pi with a non-obvious hostname.
4. **SSH probe** — TCP-connects port 22 on each candidate so you can see which
   is actually reachable. The best guess prefers an SSH-open, mDNS-named host.

Read-only — it changes nothing on your machine or the Pi. Note it identifies a
Pi by the interface that's on the network: a Pi on Wi-Fi shows its Wi-Fi MAC,
on Ethernet its (different) Ethernet MAC — both are Pi OUIs.

## Use it (from Windows)

> **Connect the Pi over Ethernet first.** `setup.sh` takes `wlan0` away from
> NetworkManager — do this over Wi-Fi and you lose the box mid-run. Use
> `find-pi.ps1` to confirm which interface it's on (Wi-Fi MAC vs Ethernet MAC).

```powershell
cd C:\Users\Aaron\repo\pi-captive-portal
Copy-Item portal.env.example portal.env
notepad portal.env            # set PI_HOST/PI_USER, SSID, WPA_PASSPHRASE, etc.

.\deploy.ps1                  # no args -> interactive menu
```

Run with no arguments for a menu (full deploy / push page / push guestbook /
pull posts / rollback), or pass a switch directly to skip it.

Overrides and rollback:

```powershell
.\deploy.ps1 -PiHost 192.168.1.42 -PiUser pi
.\deploy.ps1 -Rollback        # undo everything, hand wlan0 back to NetworkManager
```

### Iterating on the page

Editing `www/index.html`? Push just the web content — seconds, no reinstall:

```powershell
.\deploy.ps1 -PageOnly        # ships www/* to /var/www/portal (nginx needs no reload)
```

Iterating on the guestbook app or its template?

```powershell
.\deploy.ps1 -Guestbook       # ships guestbook/* to /opt/guestbook + restarts service
```

Then reload the portal/guestbook on a connected client. (A change to
`guestbook/requirements.txt` needs a full `.\deploy.ps1` — quick-push doesn't
reinstall Python deps.)

## Guestbook (optional)

A 90s-style SQLite guestbook, off unless `GUESTBOOK=1` in `portal.env`.

- Flask + gunicorn on `127.0.0.1:8080`, run by systemd as `www-data`
  (`guestbook.service`); nginx reverse-proxies `/guestbook` to it.
- SQLite DB at `/var/lib/portal/guestbook.db` — kept outside the app dir so
  redeploys and rollbacks never wipe signed entries.
- Output is HTML-escaped (Jinja autoescape) and SQL is parameterised; name and
  message are length-capped. Linked from the portal splash page.

| Path | What it is |
|---|---|
| `guestbook/app.py` | Flask app — stdlib `sqlite3`, no ORM. |
| `guestbook/templates/guestbook.html` | The form + entries list. |
| `guestbook/guestbook.service` | systemd unit. |
| `guestbook/requirements.txt` | Flask + gunicorn (pinned). |

To disable later: set `GUESTBOOK=0` and re-run `.\deploy.ps1`, or
`.\deploy.ps1 -Rollback` (which leaves the DB intact).

### Pulling the posts off the Pi

```powershell
.\deploy.ps1 -PullGuestbook                    # -> guestbook-YYYYMMDD-HHmmss.csv
.\deploy.ps1 -PullGuestbook -OutFile posts.csv # custom path
```

Reads the DB through SQLite (so WAL entries aren't missed) with `sudo`, writes a
UTF-8 CSV (`id, created_at, name, message`) and pulls it back. Exports are
git-ignored. If you'd rather grab the raw database file for backup:

```powershell
ssh pi@raspberrypi.local "sudo cp /var/lib/portal/guestbook.db /tmp/gb.db && sudo chmod 644 /tmp/gb.db"
scp pi@raspberrypi.local:/tmp/gb.db .\guestbook.db
ssh pi@raspberrypi.local "rm -f /tmp/gb.db"
```

### Dump endpoint (no SSH needed)

**From a device connected to the portal Wi-Fi**, fetch every post over HTTP:

```
http://192.168.4.1/guestbook/dump             # JSON
http://192.168.4.1/guestbook/dump?format=csv  # CSV download
```

No auth — anyone on the isolated portal network can hit it. That's fine for this
walled-garden LAN; don't expose the endpoint to an untrusted network.

Requires the Windows OpenSSH client (`ssh`, `scp`) — bundled with Windows 10/11;
enable via *Settings > System > Optional features* if missing.

## Run setup directly on the Pi (no Windows)

```bash
cp portal.env.example portal.env && nano portal.env
sudo ./setup.sh            # install
sudo ./setup.sh rollback   # undo
```

## Verify

```bash
iw dev wlan0 info | grep type            # type AP
dig @127.0.0.1 example.com +short        # -> 192.168.4.1
curl -sI http://127.0.0.1/generate_204   # 302
```

Join the SSID from a phone; the captive-portal sheet should appear in a few
seconds. If not, load `http://neverssl.com` manually. Known limits (HTTPS
interception, Android Private DNS) are documented in `pi3-captive-portal.md`.
