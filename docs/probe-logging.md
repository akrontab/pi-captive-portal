# Probe-request logging (monitor mode)

**Status:** implemented (`probe/portal-probe-logger.py` + `.service`, wired into
`setup.sh`). **OFF by default** — it needs a dedicated second radio, so it stays
disabled until the AR9271 is the AP and the rt2800usb is free to monitor.

## What it does

Wi-Fi devices that aren't connected periodically broadcast **probe requests** —
unencrypted 802.11 management frames that carry the device's MAC and, often, the
name of a network it's looking for (its "preferred network list" leaking into the
air). This daemon listens for those frames on a monitor interface, channel-hops
to cover the 2.4 GHz band, and records:

- **devices** — MAC, vendor (small built-in OUI map), randomized-MAC flag, signal
  (dBm), first/last seen, probe count.
- **probes** — each `(device, SSID)` pair it asked for, with counts and timing.
  An empty SSID = a broadcast/wildcard probe (device just asking "anyone there?").

It's the passive half of the WiFi-Pineapple-style demo: pair it with the bait
SSIDs (`docs/multi-ssid.md`) and you can *see* what networks people's phones are
hunting for, then optionally beacon those names back.

## Why it needs its own radio

A radio does one channel at a time, and the rt2800usb won't do AP+monitor in a
single interface combination at all (`docs/radio-capabilities.md`). So the AP
radio can't also sniff. The split, once the AR9271 arrives:

- **AR9271 (`ath9k_htc`) → multi-BSS AP** (`Portal` + baits), pinned to one channel.
- **rt2800usb → monitor**, free to channel-hop 1/6/11 and harvest probes band-wide.

Turning `PROBE_LOG=1` flips `MONITOR_IF` into monitor mode — so **never point it at
the AP's radio** (`setup.sh` refuses if `MONITOR_IF == WLAN_IF`). On the Pi 2,
two USB Wi-Fi radios want a powered hub; pin interface names by MAC (a systemd
`.link`/udev rule) since `wlanN` numbering can swap on boot.

## How it works

`tcpdump` does the capture with a kernel BPF filter
(`type mgt subtype probe-req`) — efficient, no busy-polling in Python. The daemon
reads tcpdump's **pcap stream** on stdout and parses each frame itself (radiotap
signal → 802.11 addr2 → SSID tag), so it doesn't depend on tcpdump's text output.
A background thread channel-hops via `iw dev <mon> set channel`. Writes go to
SQLite (`/var/lib/portal-probe/probes.db`, WAL, batched commits to spare the SD card),
upserting per device and per `(device, SSID)`.

No web app, no root in the web tier — it's a standalone root daemon, same pattern
as the other privileged sidecars.

## Enable it

Once the second radio is in place and confirmed as `MONITOR_IF`:

```sh
# portal.env
PROBE_LOG=1
MONITOR_IF=wlan1          # the monitor radio — must NOT equal WLAN_IF
PROBE_CHANNELS=1,6,11
```

Then `./deploy.ps1` (or `sudo ./setup.sh` on the Pi). Check it:

```sh
systemctl status portal-probe-logger
sudo -u portal-probe python3 /opt/portal-probe-logger.py --report      # summary from the DB
```

`--report` prints device count, randomized-MAC share, the top SSIDs devices are
searching for, wildcard-probe volume, and the most recently seen devices.

## Testing without hardware

`python3 probe/portal-probe-logger.py --selftest` builds a synthetic
radiotap+probe-req frame, parses it, and round-trips a row through an in-memory
DB — no root or radio needed. Used to validate the frame/pcap parser off-Pi.

## Privacy note

This logs identifiers (MACs, requested SSIDs) from *bystander* devices that never
connect — more exposure than the connect-time data we dropped for the guestbook.
It's normal on your own rig at a hacker con, and modern phones randomize their
probe MACs (the `randomized` flag marks those, and they carry no real OUI). If you
want to be conservative: keep `probes.db` short-lived (it's fine to delete between
events), or hash MACs at insert time. The daemon stores raw MACs by default so
the `--report` view is legible.
