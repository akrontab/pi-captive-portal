# Captive Portal on Raspberry Pi 2 Model B

Isolated Wi-Fi AP that serves a single local page to every client. No internet
upstream — this is a walled garden, not a gateway.

**Target:** Raspberry Pi OS (Trixie) Lite, **armhf (32-bit)**, on a Pi 2 Model B
**Network:** `192.168.4.0/24`, Pi at `192.168.4.1`
**Radio:** USB Wi-Fi adapter as `wlan0` (`rt2800usb` on the deployed rig), 2.4 GHz

> **The Pi 2B has no built-in Wi-Fi.** The AP radio has to be a USB adapter whose
> chipset supports AP mode (`iw list` → *Supported interface modes* includes
> `AP`). It shows up as `wlan0`, so every command below is the same as on a board
> with onboard Wi-Fi. The deployed `rt2800usb` adapter can only beacon one BSS,
> which is why multiple SSIDs are done as a single **rotating** SSID instead; see
> `docs/multi-ssid-adapter-upgrade.md`. Use the 32-bit image. The original Pi 2B
> (BCM2836, Cortex-A7) can't run the 64-bit OS, and on v1.2 boards (BCM2837) the
> 64-bit image isn't officially supported.

Do this over Ethernet or a directly attached keyboard. You will take `wlan0`
away from NetworkManager partway through, and if that is your only link you
will lose the box.

---

## 1. Base packages

```bash
sudo apt update
sudo apt install -y hostapd dnsmasq nginx-light iptables iptables-persistent
sudo systemctl unmask hostapd
```

Stop the services while configuring so they don't fight you:

```bash
sudo systemctl stop hostapd dnsmasq nginx
```

Unblock the radio and set a regulatory domain. Without a country code the
kernel's regulatory database keeps the radio on its most restrictive defaults
and hostapd may refuse to bring the AP up, with an unhelpful failure message:

```bash
sudo rfkill unblock wlan
sudo raspi-config nonint do_wifi_country US    # substitute your ISO code
```

---

## 2. Take wlan0 away from NetworkManager

Trixie manages all interfaces through NetworkManager by default. It will
tear down anything hostapd tries to do. Mark the interface unmanaged:

```bash
sudo tee /etc/NetworkManager/conf.d/99-portal-unmanaged.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF

sudo systemctl reload NetworkManager
```

Confirm — `wlan0` should now read `unmanaged`:

```bash
nmcli device status
```

---

## 3. Static IP on wlan0

With NetworkManager out of the picture, hand the address to
`systemd-networkd`:

```bash
sudo tee /etc/systemd/network/10-wlan0-portal.network >/dev/null <<'EOF'
[Match]
Name=wlan0

[Network]
Address=192.168.4.1/24
ConfigureWithoutCarrier=yes
EOF

sudo systemctl enable --now systemd-networkd
```

`ConfigureWithoutCarrier` matters: before hostapd starts there is no carrier
on the interface, and without it networkd will skip the address assignment.

---

## 4. hostapd

```bash
sudo tee /etc/hostapd/hostapd.conf >/dev/null <<'EOF'
interface=wlan0
driver=nl80211

ssid=Portal
country_code=US
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1

# Open network — required if you want the portal to appear without a password
auth_algs=1
wpa=0

macaddr_acl=0
ignore_broadcast_ssid=0
EOF

sudo chmod 600 /etc/hostapd/hostapd.conf
```

Point the service at the file:

```bash
sudo sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
  /etc/default/hostapd
```

**Channel choice:** pick 1, 6, or 11. The `rt2800usb` and AR9271 adapters are
2.4 GHz only. A dual-band USB adapter can do 5 GHz, but AP mode there needs DFS
handling and often just fails — stay on 2.4 GHz.

**If you want WPA2 instead of open:** add `wpa=2`, `wpa_passphrase=...`,
`wpa_key_mgmt=WPA-PSK`, `rsn_pairwise=CCMP`. The portal still works; clients
just need the key first.

---

## 5. dnsmasq — DHCP plus wildcard DNS

```bash
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

sudo tee /etc/dnsmasq.conf >/dev/null <<'EOF'
interface=wlan0
bind-interfaces
except-interface=lo

# Don't consult /etc/resolv.conf or any upstream — we answer everything ourselves
no-resolv
no-hosts

# Every hostname on earth resolves to the Pi
address=/#/192.168.4.1

dhcp-range=192.168.4.50,192.168.4.150,255.255.255.0,12h
dhcp-option=option:router,192.168.4.1
dhcp-option=option:dns-server,192.168.4.1

# RFC 8910 captive-portal URI (DHCP option 114)
dhcp-option=114,http://192.168.4.1/portal

# Short TTL so clients re-resolve after you release them
local-ttl=2

log-queries
log-dhcp
EOF
```

If `systemd-resolved` is running it will hold port 53 and dnsmasq will fail to
bind. Check and disable its stub if needed:

```bash
sudo ss -ulnp | grep :53
sudo systemctl disable --now systemd-resolved   # only if it's the one holding 53
```

---

## 6. The portal page

```bash
sudo mkdir -p /var/www/portal
sudo tee /var/www/portal/index.html >/dev/null <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0;
           display: grid; place-items: center; min-height: 100vh;
           background: #101418; color: #e8eaed; }
    main { max-width: 30rem; padding: 2rem; text-align: center; }
    h1 { font-weight: 600; }
  </style>
</head>
<body>
  <main>
    <h1>Welcome</h1>
    <p>You are connected to the local network.</p>
  </main>
</body>
</html>
EOF
```

Keep it a single self-contained file. External CSS, fonts, or scripts will not
load — there is no internet, and the captive-portal mini-browsers on iOS and
Android are stricter than a real browser about what they will fetch.

---

## 7. nginx

```bash
sudo rm -f /etc/nginx/sites-enabled/default

sudo tee /etc/nginx/sites-available/portal >/dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/portal;

    # Probe responses must never be cached, or the client will think it's
    # still behind a portal after you release it (and vice versa)
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;

    # The portal itself — exact match, so it isn't caught by the catch-all
    location = /portal {
        try_files /index.html =404;
    }

    # Everything else, including all OS probe URLs, bounces to the portal
    location / {
        return 302 http://192.168.4.1/portal;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
sudo nginx -t
```

The 302 is what does the work. Every OS probe expects an exact response
(a 204, or a specific short body); a redirect is unambiguously "not that,"
which is precisely the signal that triggers the portal popup.

---

## 8. Firewall rules

```bash
# Catch clients using hardcoded DNS (8.8.8.8 etc.) — force them to dnsmasq
sudo iptables -t nat -A PREROUTING -i wlan0 -p udp --dport 53 -j REDIRECT --to-port 53
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 53 -j REDIRECT --to-port 53

# Catch clients hitting a cached IP directly on port 80
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:80

# Kill HTTPS fast rather than letting it hang
sudo iptables -A INPUT   -i wlan0 -p tcp --dport 443 -j REJECT --reject-with tcp-reset
sudo iptables -A FORWARD -i wlan0 -p tcp --dport 443 -j REJECT --reject-with tcp-reset

sudo netfilter-persistent save
```

Leave `net.ipv4.ip_forward` at 0. There is nowhere to forward to, and disabling
it means stray traffic dies at the Pi instead of wandering.

The `tcp-reset` on 443 is deliberate — see the notes at the end.

---

## 9. Start everything

```bash
sudo systemctl enable --now hostapd dnsmasq nginx
sudo systemctl status hostapd dnsmasq nginx --no-pager
```

Order matters on first boot: hostapd brings up the carrier, networkd assigns
the address, dnsmasq binds to it. If dnsmasq starts too early it fails. Add a
dependency if you see this on reboots:

```bash
sudo systemctl edit dnsmasq
```

```ini
[Unit]
After=hostapd.service
Requires=hostapd.service
```

---

## 10. Verify

**On the Pi:**

```bash
ip addr show wlan0                          # expect 192.168.4.1/24
iw dev wlan0 info                           # expect "type AP"
dig @127.0.0.1 example.com +short           # expect 192.168.4.1
curl -sI http://127.0.0.1/generate_204      # expect 302
curl -s http://127.0.0.1/portal | head      # expect your HTML
sudo journalctl -fu dnsmasq                 # watch leases and queries live
```

**On a phone:** join the SSID. The captive-portal sheet should appear within a
few seconds. If it doesn't, open a browser and load any `http://` URL manually
— `http://neverssl.com` is a reliable test target because it has no HSTS.

Probe URLs to watch for in the dnsmasq log, by platform:

| Platform | Probe host |
|---|---|
| Android | `connectivitycheck.gstatic.com` |
| iOS / macOS | `captive.apple.com` |
| Windows | `www.msftconnecttest.com` |
| Firefox | `detectportal.firefox.com` |

---

## Notes and known limits

**HTTPS cannot be intercepted.** If the client's first request is to an
`https://` URL, there is no way to show them your page — the redirect would
have to live inside a TLS session you can't establish without a cert the client
trusts. DNAT'ing 443 to nginx produces a certificate warning, not your portal,
and on HSTS-preloaded domains not even a click-through. Rejecting with a TCP
reset at least fails in under a second instead of hanging for thirty. The plain
HTTP probes are the only reliable entry point, which is exactly why every OS
keeps them HTTP-only.

**Android Private DNS breaks the wildcard.** In strict mode, DNS goes over TLS
to a fixed resolver on port 853, bypassing dnsmasq entirely. Your `address=/#/`
rule never fires. There is no server-side fix; the user must switch Private DNS
to "Automatic." Blocking 853 makes it fail faster but doesn't recover DNS.

**Android may mark the network validated and leave.** If the HTTPS half of its
probe pair succeeds, Android can decide the network is fine without ever
showing your page — and if it decides the network is unusable, it silently
drops back to cellular. The 443 REJECT rule above prevents the first case.

**Release logic, if you add an "accept" button.** Nothing above lets clients
out, by design. If you later add an upstream, the pattern is: add the client's
MAC to an allowed ipset on button press, exempt that ipset from the DNAT and
REJECT rules, and let the next OS probe reach the real internet and return its
genuine 204. That success is what clears the portal state on the client.

**Pi 2B capacity.** Budget for roughly 10–15 concurrent clients on a basic USB
2.4 GHz adapter before throughput degrades noticeably. The Pi 2B's Ethernet and
all four USB ports share a single USB 2.0 link, and the board is slow, but a
single static page isn't the bottleneck; the radio is. A stronger AP-capable
chipset (MT7612U, RTL8812AU) helps, but it draws more current, so put it on a
**powered USB hub** (see `docs/multi-ssid-adapter-upgrade.md`).

**Rolling it back:**

```bash
sudo systemctl disable --now hostapd dnsmasq
sudo rm /etc/NetworkManager/conf.d/99-portal-unmanaged.conf
sudo rm /etc/systemd/network/10-wlan0-portal.network
sudo systemctl reload NetworkManager
sudo iptables -F && sudo iptables -t nat -F && sudo netfilter-persistent save
```
