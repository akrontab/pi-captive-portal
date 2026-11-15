# pi-captive-portal

Isolated Wi-Fi AP on a Raspberry Pi 2 Model B that serves one local page to
every client — a walled garden, no internet upstream. hostapd + dnsmasq + nginx.

## Features

- **Captive-portal pop-up on join.** Wildcard DNS and an HTTP redirect answer
  every phone and laptop's connectivity check (`/generate_204` and friends), so
  the OS opens the portal sheet by itself. HTTPS is rejected so devices don't
  skip it. There's no upstream; nothing gets out.
- **A 90s hyperpop/glitchcore splash page.** One self-contained
  `www/index.html` with a retro nixie hit counter, floating friend faces, and
  easter eggs to find. Design notes: `docs/90s-hyperpop-restyle.md`.
- **Embedded guestbook.** Visitors sign it from the splash page (Flask +
  gunicorn + SQLite). Posts survive redeploys and can be pulled to Windows as
  CSV/JSON with one command, or read over HTTP at `/guestbook/dump`.
- **Rotating SSID.** The network name changes on a timer (default every 15 min)
  from a pool in `ssids.txt`. The USB radio can only broadcast one network at a
  time, so this stands in for multi-SSID bait networks; see `docs/multi-ssid.md`.
- **Built to sit on a hostile network.** It's made to run at a hacker conference:
  parameterised SQL, inert stored XSS, CSV-injection escaping, and a sandboxed
  guestbook service. See `docs/security-hardening.md`.
- **SSH only from the Pi's Ethernet port.** The firewall drops port 22 on the
  Wi-Fi side, so nobody connected to the portal can even reach SSH. Login is
  key-only (password auth is off) and happens over the wired port.
- **Probe-request logging (optional).** With a second USB radio in monitor
  mode, it logs nearby devices and the network names they're searching for into
  SQLite. Off by default; see `docs/probe-logging.md`.
- **Failure forensics.** Persistent journald plus a 60-second power/USB health
  logger (under-voltage, throttling, USB attach/detach), so a crash or power cut
  leaves evidence. Example: [`radio-failure/`](radio-failure/radio-failure.md).
- **One-command deploy from Windows.** `deploy.ps1` pushes and runs the
  idempotent `setup.sh` over SSH. Quick-push modes handle page-only or
  guestbook-only changes, and there's a full rollback. Every setting lives in
  `portal.env`.

**Hardware:** Pi 2 Model B running Raspberry Pi OS (Trixie) Lite **armhf
(32-bit)**. The Pi 2B has **no built-in Wi-Fi**, so the AP radio is a USB adapter
(`rt2800usb`) that shows up as `wlan0`. Ethernet is the management link. If you
run more than one USB radio, use a **powered USB hub**: the Pi 2B can't supply
two adapters from its own ports.

Full annotated walkthrough of every step lives in
[`pi2-captive-portal.md`](pi2-captive-portal.md). This README is the scripted path.

## See it in action

- [Demo 1 (YouTube Short)](https://youtube.com/shorts/lY3wrJ3sY7c)
- [Demo 2 (YouTube Short)](https://youtube.com/shorts/QkFL4eGP6MY)

## Layout

| Path | What it is |
|---|---|
| `portal.env.example` | All tunables (SSID, IP, channel, WPA…). Copy to `portal.env`. |
| `deploy.ps1` | **Windows** driver — scp files to the Pi, run `setup.sh` over SSH. |
| `setup.sh` | Runs **on the Pi** as root. Idempotent. `install` / `rollback`. |
| `config/*.tmpl` | hostapd, dnsmasq, networkd, nginx — `@TOKEN@` rendered from `portal.env`. |
| `www/index.html` | The served portal page (single self-contained file). |
| `health/` | Power/USB health logger (systemd timer) for failure forensics. |

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
Pi by the interface that's on the network. On the Pi 2B that's the onboard
Ethernet (`b8:27:eb`, a Pi OUI). A USB Wi-Fi adapter carries **its own vendor's
MAC**, so a Pi 2B reached over Wi-Fi won't match an OUI; only mDNS will find it.

## Use it (from Windows)

> **Connect the Pi over Ethernet first.** `setup.sh` takes `wlan0` away from
> NetworkManager — do this over Wi-Fi and you lose the box mid-run. Use
> `find-pi.ps1` to confirm it's on Ethernet (a `b8:27:eb` Pi OUI match).

```powershell
cd C:\Users\Aaron\repo\pi-captive-portal
Copy-Item portal.env.example portal.env
notepad portal.env            # set PI_HOST/PI_USER, SSID, WPA_PASSPHRASE, etc.

.\deploy.ps1                  # no args -> interactive menu
```

Run with no arguments for a menu (full deploy / push page / push guestbook /
pull posts / rollback), or pass a switch directly to skip it.

### Pi prerequisites (one-time)

`deploy.ps1` drives the Pi over a **non-interactive** SSH session, so the Pi has
to admit it with no prompts of any kind:

- **SSH key auth for the deploy target.** `~/.ssh/pi-captive-portal` (ed25519) is
  the Pi's key; `~/.ssh/config` must offer it for the exact `PI_HOST` you set in
  `portal.env`. The `Host` line has to list that host/IP verbatim:

  ```
  Host pi.local pi-portal 192.168.40.233
      User pi
      IdentityFile ~/.ssh/pi-captive-portal
      IdentitiesOnly yes
  ```

  If `PI_HOST` is an IP that isn't on that line, SSH never offers the key and the
  deploy dies with `Permission denied (publickey)` — password auth is off on the
  Pi (see `docs/security-hardening.md`).

- **Passwordless sudo.** `setup.sh` and the page/guestbook pushes run `sudo` over
  that non-interactive session, which has no terminal to type a sudo password into
  (`sudo: a terminal is required to read the password`). **`setup.sh` now installs
  this itself** (`/etc/sudoers.d/011_pi-nopasswd` for the invoking user, validated
  with `visudo -cf`; controlled by `NOPASSWD_SUDO` in `portal.env`). The catch is
  bootstrap: the *first* `sudo ./setup.sh` still needs a password — `deploy.ps1`
  handles this by running it over `ssh -t` (interactive), so just enter the `pi`
  password that once and every deploy after is unattended.

  To enable it up front without a full deploy, run this once from an interactive
  shell (enter the `pi` password when prompted):

  ```bash
  ssh -t pi@<host> "echo 'pi ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/011_pi-nopasswd >/dev/null && sudo chmod 440 /etc/sudoers.d/011_pi-nopasswd && sudo visudo -cf /etc/sudoers.d/011_pi-nopasswd"
  ```

  It should end `parsed OK`. Why this is acceptable under the conference threat
  model: `docs/security-hardening.md` → *SSH & sudo*.

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
.\deploy.ps1 -PullGuestbook                    # CSV  -> guestbook-YYYYMMDD-HHmmss.csv
.\deploy.ps1 -PullGuestbook -OutFile posts.csv # custom path
.\deploy.ps1 -PullJson                         # JSON -> guestbook-YYYYMMDD-HHmmss.json
.\deploy.ps1 -PullJson -OutFile posts.json     # custom path
.\deploy.ps1 -PullProbes                       # CSV  -> probes-YYYYMMDD-HHmmss.csv
.\deploy.ps1 -PullAll                          # guestbook JSON + probes CSV, both
```

`-PullGuestbook` reads the DB through SQLite (so WAL entries aren't missed) with
`sudo`, writes a UTF-8 CSV (`id, created_at, name, message`) and pulls it back.
`-PullJson` curls the `/guestbook/dump` endpoint on the Pi (via localhost, so it
works regardless of client-network rules) and pulls the JSON — every entry with
its full captured `meta` block. `-PullProbes` exports the probe DB
(`/var/lib/portal/probes.db`, `probes` joined with `devices`) to a CSV — one row
per `(device, requested SSID)` with vendor, randomized-MAC flag, counts, and
signal; it degrades to a header-only file if probe logging was never enabled.
`-PullAll` grabs the guestbook JSON and the probes CSV in one run. All are
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

No auth — **anyone on the portal Wi-Fi (`192.168.4.0/24`) can hit it**, by
design (`setup.sh` allows the portal subnet + localhost, denies everything else).
That means each connected client can pull *every* visitor's captured
fingerprint data (MACs, hostnames, UAs). If that's not what you want at a hostile
event, lock it back to localhost in `configure_nginx` and pull with `-PullJson` /
`-PullGuestbook` instead — see `docs/security-hardening.md`.

Requires the Windows OpenSSH client (`ssh`, `scp`) — bundled with Windows 10/11;
enable via *Settings > System > Optional features* if missing.

## Probe logging (optional, needs a second radio)

Passively logs 802.11 probe-requests — each nearby device's MAC and the SSIDs
it's searching for — on a **dedicated monitor radio** (the AP radio can't also
monitor). **OFF by default** (`PROBE_LOG=0`); enable it only once a second Wi-Fi
adapter is present as `MONITOR_IF` (the intended split: AR9271 = AP, rt2800usb =
monitor). Standalone root daemon (`portal-probe-logger.service`), tcpdump-based
capture, SQLite at `/var/lib/portal/probes.db`. View with
`sudo python3 /opt/portal-probe-logger.py --report`. Full write-up and the
privacy note: `docs/probe-logging.md`.

### When the second radio (AR9271) arrives — do this

The plan: the **AR9271 becomes the AP** (and finally lights up multi-SSID baits),
and the existing **rt2800usb becomes the probe monitor**. Steps:

1. **Plug it in.** On the Pi 2, run both radios off a **powered USB hub** — two
   USB Wi-Fi adapters exceed the Pi's own port current budget. Watch for brownout
   after: `dmesg | grep -i under.voltage`.

2. **Identify the interfaces and which driver is which:**
   ```sh
   for i in /sys/class/net/wlan*; do
     n=$(basename "$i"); echo "$n -> $(readlink -f "$i/device/driver" | sed 's#.*/##') $(cat "$i/address")"
   done
   # expect one 'ath9k_htc' (the AR9271, your new AP) and one 'rt2800usb' (monitor)
   ```

3. **Pin the names by MAC** so `wlanN` can't swap on reboot (it will, otherwise).
   Create a `.link` file per adapter with its MAC — e.g. AR9271 → `wlan0`,
   rt2800usb → `wlan1`:
   ```sh
   sudo tee /etc/systemd/network/10-ap.link >/dev/null <<'EOF'
   [Match]
   MACAddress=aa:bb:cc:dd:ee:ff        # <-- the AR9271's MAC
   [Link]
   Name=wlan0
   EOF
   # repeat as 11-mon.link with the rt2800usb's MAC and Name=wlan1, then reboot
   ```

4. **Edit `portal.env`:** point the AP at the AR9271 and turn baits + probe
   logging on:
   ```sh
   WLAN_IF=wlan0            # the AR9271 (the AP radio)
   SSID_ROTATE=1            # baits can finally beacon on this chip
   SSID_BAIT_COUNT=7        # AR9271 should do the full 7; verify in step 6
   PROBE_LOG=1
   MONITOR_IF=wlan1         # the rt2800usb (must NOT equal WLAN_IF)
   ```
   Make sure `ssids.txt` has your bait names (copy `ssid/ssids.txt.example`).

5. **Deploy:** `.\deploy.ps1` (over Ethernet, as always).

6. **Verify:**
   ```sh
   /usr/sbin/iw dev wlan0 info | grep type            # expect: type AP
   sudo journalctl -u hostapd | grep AP-ENABLED       # one line PER bait BSS now
   # from a phone/laptop: scan and confirm Portal + all baits are visible
   systemctl status portal-probe-logger
   sudo python3 /opt/portal-probe-logger.py --report  # devices + probed SSIDs
   ```
   If fewer than 7 baits beacon, lower `SSID_BAIT_COUNT` to what the chip
   actually broadcasts. If a bait fails, check `docs/multi-ssid-adapter-upgrade.md`.

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
interception, Android Private DNS) are documented in `pi2-captive-portal.md`.

## Logs & failure analysis

Raspberry Pi OS keeps the systemd journal **in RAM only**
(`/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`), so every
log is lost on reboot or power cut, which is exactly when you need it. That is
why the AR9271 failure in [`radio-failure/`](radio-failure/radio-failure.md) has
no logs from the moment it died. `setup.sh` now fixes that by default:

| `portal.env` knob | Default | Effect |
|---|---|---|
| `PERSISTENT_LOGS` | `1` | Drop-in `/etc/systemd/journald.conf.d/50-portal-persistent.conf` sets `Storage=persistent`; journal lives in `/var/log/journal`. |
| `JOURNAL_MAX_USE` | `200M` | Disk cap for the journal (oldest entries rotate out). |
| `JOURNAL_SYNC_INTERVAL` | `30s` | Max log lost to a sudden power cut (journald default is 5min). |
| `HEALTH_LOG` | `1` | `portal-health.timer` logs throttle/under-voltage flags, temp, core volts, USB devices (port, ID, speed), hub over-current counters and `wlan*` interfaces every 60s. |

Health lines are tagged warning when the board reports under-voltage or
throttling, or when a USB device appears/disappears or an over-current counter
moves, so the useful ones filter out easily. Kernel messages (USB disconnects,
`Undervoltage detected!`, driver errors) are in the same journal.

```bash
journalctl --list-boots                          # every boot, now kept across power cycles
journalctl -b -1 -e                              # end of the PREVIOUS boot (what happened before it died)
journalctl -b -1 -k                              # previous boot, kernel only
journalctl -t portal-health -p warning           # power/USB events only
journalctl -t portal-health --since "2 hours ago"
journalctl -k | grep -iE "voltage|usb|over-?current|ath9k|rt2800"
```

Pull a boot's logs to Windows for analysis:

```powershell
ssh pi.local "sudo journalctl -b -1 -o short-iso --no-pager" > prev-boot.log
```

**Clock caveat:** the Pi has no battery-backed RTC. At boot the clock starts
from the last time `systemd-timesyncd` synced, then jumps once NTP syncs, so
early-boot timestamps can read days in the past. `journalctl` keys entries by
boot ID and monotonic time, so per-boot ordering is still correct; use
`-o short-monotonic` when wall-clock time looks wrong.

Not covered by logging: `max_usb_current=1` in `config.txt` (applies to the
Pi 2B and B+; lifts the shared USB current limit from 600mA to 1.2A). That's a
power change, not a logging one; it's left to you. It needs a supply that can
deliver it (2.5A recommended), and a powered hub is still the safer fix for two
radios.
