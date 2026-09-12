# Multi-SSID + bait rotation

Broadcast several Wi-Fi SSIDs from the one radio, and (optionally) reshuffle the
"bait" set on a timer. The rt2800usb USB adapter advertises `#{AP,mesh}<=8,
#channels<=1`, so up to **8 BSSes total on one channel** — the stable primary
(`SSID` in `portal.env`) plus up to **7 baits**.

## How it fits together
- **`config/hostapd.conf.tmpl`** still describes only the primary BSS. At install
  `setup.sh` renders it (plus the security block) into
  **`/etc/hostapd/hostapd.base.conf`** — the primary never changes at runtime.
- **`ssid/portal-ssid-rotate.py`** reads that base, appends `bss=wlan0_N` stanzas
  for a random selection from the bait pool, writes the live
  **`/etc/hostapd/hostapd.conf`** (0600), and restarts hostapd. Config comes from
  **`/etc/portal-ssid.env`** (written by `setup.sh`).
- **`ssid/portal-ssid-rotate.{service,timer}`** run the engine as root on a timer
  when rotation is enabled. `setup.sh` rewrites `OnUnitActiveSec` to
  `SSID_ROTATE_INTERVAL`.

The primary "Portal" BSS is the interface stanza, so it is never rotated — only
the bait `bss=` blocks are rewritten. hostapd has no runtime add/remove-BSS, so a
reshuffle restarts hostapd, which briefly drops **all** clients (primary
included). Keep `SSID_ROTATE_INTERVAL` generous (default 15min).

## Configure (`portal.env`)
```
SSID=Portal                  # the stable primary (never rotates)
SSID_ROTATE=1                # 1 = reshuffle baits on a timer; 0 = static set
SSID_ROTATE_INTERVAL=15min   # systemd time: 30s, 5min, 1h, ...
SSID_BAIT_COUNT=7            # baits broadcast at once (max 7)
```
Put the bait names in **`ssids.txt`** (copy `ssids.txt.example`), one per line,
`#` for comments, each name ≤ 32 bytes. `ssids.txt` is git-ignored. With **no**
`ssids.txt` you get a single SSID, exactly as before rotation existed.

- `SSID_ROTATE=0` + a pool → a **static** multi-SSID set (chosen once at install).
- `SSID_ROTATE=1` + a pool → the set reshuffles every interval.

## Deploy & verify
Full deploy (installs the units + builds the first live config):
```
.\deploy.ps1      # choose 1) Full deploy, over Ethernet
```
On the Pi:
```
grep -c '^bss=' /etc/hostapd/hostapd.conf         # number of live baits
iw dev wlan0 info                                  # primary
sudo systemctl list-timers portal-ssid-rotate.timer
sudo journalctl -u portal-ssid-rotate -n 20        # "[portal-ssid] ... baits=[...]"
# force a reshuffle now:
sudo systemctl start portal-ssid-rotate.service
```

## Notes / limits
- BSSIDs are auto-assigned by hostapd from the primary's address. If a bait BSS
  fails to start on this driver, add explicit locally-administered `bssid=` lines
  to the stanzas in `portal-ssid-rotate.py`.
- All BSSes share one channel (radio limit) and the open/WPA settings of the
  primary block.
- Rollback (`setup.sh rollback`, or `.\deploy.ps1` → 5) removes the units, the
  engine, `/etc/portal-ssid.env`, `/etc/portal-ssids.txt`, and the base config.
