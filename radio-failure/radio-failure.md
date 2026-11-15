# AR9271 USB Wi-Fi Adapter Failure Report

**Prepared:** 2026-10-22
**Status:** Adapter does not enumerate on USB. Investigation in progress.

## Summary

An Atheros AR9271 USB Wi-Fi adapter used as a Wi-Fi access point on a Raspberry Pi
stopped working on or around the evening of 2026-10-06 (US Mountain time). It is
no longer recognized as a USB device. When it was plugged back in for testing on
2026-10-22, the host detected an electrical connection, but the adapter came up at
USB **full speed** (12 Mbps) instead of **high speed** (480 Mbps) and then dropped
off the bus without ever returning its device descriptor (vendor/product ID). A
working AR9271 enumerates at high speed as `0cf3:9271`.

The host itself is healthy. The second USB Wi-Fi adapter (Ralink RT5370) on the same
host keeps working normally. The host shows no under-voltage, throttling, or USB
over-current events on the current boot.

## Adapter details

| Item                         | Value                                                             |
| ---------------------------- | ----------------------------------------------------------------- |
| Chipset                      | Atheros AR9271 (Linux driver `ath9k_htc`, firmware `htc_9271.fw`) |
| Expected USB ID              | `0cf3:9271`, high speed (480 Mbps)                                |
| MAC address                  | `00:11:7f:20:f0:5e`                                               |
| Product / model              | AR9271 Wifi Adapter                                               |
| Order number / purchase date | Order#216579                                                      |
| Role                         | Wi-Fi access point (hostapd), 2.4 GHz                             |

## Host details

| Item                   | Value                                                        |
| ---------------------- | ------------------------------------------------------------ |
| Board                  | Raspberry Pi 2 Model B Rev 1.1                               |
| OS kernel              | Linux 6.18.34+rpt-rpi-v7 (Raspberry Pi OS)                   |
| Board firmware         | 2026-05-21 (hash `288930ab4712b99596f32732664aaaeb881ef1e0`) |
| USB                    | On-board SMSC LAN9514 hub, 4 external USB 2.0 ports          |
| Other USB Wi-Fi        | Ralink RT5370 (`148f:5370`), working normally                |
| Network for management | Wired Ethernet (unaffected)                                  |

## Timeline

Times are US Mountain (MDT, UTC-6) unless marked UTC.

| When                              | Event                                                                                                                                                                                                                      | Source                          |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| 2026-10-05                        | AR9271 installed as the access-point radio. Interface naming pinned to its MAC so it always appears as `wlan0`.                                                                                                            | Project notes                   |
| 2026-10-05, late evening          | Boot with both USB radios connected directly to the Pi (no powered hub) hung. With only the AR9271 connected, the system booted normally and the AR9271 was detected and working.                                          | Project notes, `cloud-init.log` |
| 2026-10-06, about 15:51 to 19:19  | Four boots. AR9271 detected (`wlan0` present) on every one.                                                                                                                                                                | `cloud-init.log`                |
| 2026-10-06, 15:00 to 22:01        | Wi-Fi clients connected through the AR9271 and loaded pages from the host. 16 distinct clients.                                                                                                                            | nginx access log                |
| 2026-10-06 22:01:14               | Last request from any Wi-Fi client. A client that had been requesting a page every 2 seconds stops abruptly.                                                                                                               | nginx access log                |
| 2026-10-06, about 23:04 and 23:40 | Two further boots. **AR9271 not detected** on either.                                                                                                                                                                      | `cloud-init.log`                |
| 2026-10-06 to 2026-10-22          | Adapter disconnected and set aside.                                                                                                                                                                                        | Owner                           |
| 2026-10-22 11:31                  | Host booted with only the RT5370 connected. Throttle flags `0x0` (no under-voltage since boot).                                                                                                                            | `system-state.txt`, `dmesg.txt` |
| 2026-10-22 11:52:34               | AR9271 plugged into USB port 2. Kernel logs `usb 1-1.2: new full-speed USB device number 5 using dwc_otg`. No further messages: no descriptor, no vendor/product ID, no driver load. Port state returns to "not attached". | `logs/02-after-replug/`         |
| 2026-10-22 11:53 to 11:56         | Rechecked: no additional attach attempts, port over-current counters all 0, throttle flags still `0x0`.                                                                                                                    | `logs/02-after-replug/`         |

### Notes on timeline accuracy

- The Raspberry Pi has no battery-backed real-time clock. At boot, its clock
  starts from the last time it synchronized, then corrects itself once it reaches
  a time server. Boot times above come from `cloud-init.log` stamps taken about 30
  seconds after power-on, before that correction. They are accurate for the order
  of events but may be earlier than the actual boot time.
- The nginx timestamps come from the running system after time sync and are
  reliable.
- Radio presence per boot is inferred from whether `cloud-init` read the network
  interface `wlan0`. That name is pinned to the AR9271's MAC address, so `wlan0`
  present means the AR9271 was detected on that boot.
- The failure happened between 2026-10-06 22:01 (last confirmed client traffic,
  which may also just be when the last client left) and the boot at about 23:04
  (first boot without the adapter).

## Findings

1. **The adapter no longer enumerates.** On reconnection, the host's USB hub sees a
   device attach, but at full speed instead of high speed, and the device disappears
   before it returns a device descriptor. The host-side driver and firmware never come
   into play. A full-speed attach from a high-speed-only device usually means its
   USB 2.0 high-speed handshake (chirp) failed. That points to a fault in the
   adapter's USB interface, its connector, or its cable.
2. **The host port is not the cause.** The other adapter works on the same hub,
   and no USB port has recorded an over-current event. Port 2, where the AR9271 was
   tested, can be cross-checked with the working adapter.
3. **No power problem is visible on the current boot.** `vcgencmd get_throttled`
   reports `0x0`, which means no under-voltage or throttling since boot. Core
   voltage is a steady 1.3125 V and the board temperature is 36 to 40 C.
4. **No logs exist from the moment of failure.** Raspberry Pi OS keeps its
   system log in memory only by default, so the kernel and service logs from
   2026-10-06 were lost when the host restarted. The project has since been
   changed to keep logs across restarts and to record power and USB status every
   minute, so a repeat failure would be captured.

## Operating conditions (disclosed for completeness)

- The adapter was powered directly from the Raspberry Pi 2's USB port, wihout a
  powered hub. The Pi 2 shares a 600 mA limit across all of its USB ports by
  default (`max_usb_current` was not raised).
- On 2026-10-05, a boot with both USB radios connected directly to the Pi hung.
  It was attributed to the combined power draw at boot. After that, the AR9271 ran
  as the only radio (as confirmed in the timeline) until the failure.
- The adapter was used continuously as an access point with periodic restarts of
  the access-point software.

## Evidence files

All collected read-only from the host. No settings on the host were changed
during this investigation.

| File                                                          | Contents                                                                                                            |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `logs/01-before-replug/system-state.txt`                      | Board, kernel, throttle flags, voltages, USB tree, port over-current counters, interfaces, journal settings         |
| `logs/01-before-replug/dmesg.txt`                             | Kernel log for the 2026-10-22 boot, before the adapter was reconnected                                              |
| `logs/01-before-replug/journal-current-boot.txt`              | Full system log for the 2026-10-22 boot                                                                             |
| `logs/01-before-replug/journal-boots.txt`                     | Boots retained by the system log (only the current one, see Finding 4)                                              |
| `logs/01-before-replug/cloud-init.log`                        | Per-boot record back to 2026-06-18, used for the radio presence timeline. Wi-Fi credentials redacted.               |
| `logs/01-before-replug/boot-config.txt`                       | Raspberry Pi `config.txt` and kernel command line                                                                   |
| `logs/01-before-replug/systemd-network.txt`                   | Interface pinning by MAC address                                                                                    |
| `logs/01-before-replug/nginx-2026-10-06.log`                  | Web server log for 2026-10-06. **Contains client IP addresses and browser identifiers; do not send to the vendor.** |
| `logs/02-after-replug/system-state.txt`                       | Same checks one minute after reconnection                                                                           |
| `logs/02-after-replug/dmesg.txt`                              | Kernel log including the 11:52:34 attach event                                                                      |
| `logs/02-after-replug/journal-since-1150.txt`                 | System log from 11:50 onward                                                                                        |
| `logs/02-after-replug/recheck-1155.txt`, `recheck-latest.txt` | Follow-up checks showing no further attach attempts                                                                 |

### Per-boot radio presence (from `cloud-init.log`)

Stamps are UTC and taken before time sync (see timeline notes).

| Boot stamp (UTC)                                             | AR9271 (`wlan0`) | RT5370 (`wlan1`) |
| ------------------------------------------------------------ | ---------------- | ---------------- |
| 2026-10-06 05:29                                             | yes              | yes              |
| 2026-10-06 05:47                                             | yes              | no               |
| 2026-10-06 21:51                                             | yes              | no               |
| 2026-10-06 22:57                                             | yes              | no               |
| 2026-10-07 00:08                                             | yes              | no               |
| 2026-10-07 01:19                                             | yes              | no               |
| 2026-10-07 05:04                                             | **no**           | no               |
| 2026-10-07 05:40                                             | **no**           | no               |
| 2026-10-07 06:56 (actually 2026-10-22, clock not yet synced) | no (unplugged)   | yes              |

### Links to Hardware

| Hardware      | Link                                                                                                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| AR9271 module | https://www.alibaba.com/product-detail/AR9271-AR9271L-Wireless-LAN-Card-Module_62338279880.html?spm=a2700.prosearch.normal_offer.6.1ab067af1tMoPg&priceId=9189b1db774a4c209be32f6e60ad9849 |