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

## Use it (from Windows)

> **Connect the Pi over Ethernet first.** `setup.sh` takes `wlan0` away from
> NetworkManager — do this over Wi-Fi and you lose the box mid-run.

```powershell
cd C:\Users\Aaron\repo\pi-captive-portal
Copy-Item portal.env.example portal.env
notepad portal.env            # set PI_HOST/PI_USER, SSID, WPA_PASSPHRASE, etc.

.\deploy.ps1                  # ship + install
```

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

Then reload the portal on a connected client.

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
