# How to check what the Wi-Fi radio can do

A field guide to interrogating a Wi-Fi adapter with `iw` — what it supports, what
it's doing right now, and how to read the parts that decide whether features like
multi-SSID, monitor-mode probe logging, or KARMA are even possible.

Worked examples use **this project's** adapter: a USB **rt2800usb** on the Pi,
which enumerates as `phy0` / `wlan0`.

> On the Raspberry Pi OS Lite image `iw` isn't on the non-login `PATH`; use the
> full path **`/usr/sbin/iw`**. Most `iw` *reads* work without `sudo`; changing
> state (adding interfaces, setting monitor mode) needs root.

---

## 0. The map: driver → phy → interface

Three names refer to the same hardware at different layers:

- **driver** — the kernel module (e.g. `rt2800usb`). Capabilities and quirks are
  the driver's, not the chip's alone.
- **phy** — the radio itself (`phy0`). This is what `iw phy` queries and what
  interface-combination limits apply to.
- **interface** — a logical netdev on top of the phy (`wlan0`, `wlan0_0`,
  `mon0`). One phy can host several, within limits (see §3).

Find them:
```sh
# driver behind wlan0
readlink -f /sys/class/net/wlan0/device/driver | sed 's#.*/##'   # -> rt2800usb

# list radios (phys)
ls /sys/class/ieee80211/                                          # -> phy0
/usr/sbin/iw dev                                                  # phys + their interfaces
```

---

## 1. The one command: `iw phy <phy> info`

Everything the radio *can* do lives here:
```sh
/usr/sbin/iw phy phy0 info        # or: iw list   (dumps all phys)
```
It's long. The sections that matter are below. Handy filters:
```sh
/usr/sbin/iw phy phy0 info | sed -n '/Supported interface modes/,/Band/p'
/usr/sbin/iw phy phy0 info | grep -A6 'valid interface combinations'
```

---

## 2. Supported interface modes — *what roles it can play*

```sh
/usr/sbin/iw phy phy0 info | sed -n '/Supported interface modes/,/^\tBand/p'
```
This project's rt2800usb reports:
```
Supported interface modes:
   * IBSS          (ad-hoc)
   * managed       (normal client / station)
   * AP            (access point  <- we need this)
   * AP/VLAN
   * monitor       (raw capture   <- needed to sniff/log probes)
   * mesh point
```
Takeaways: it can be an **AP** (the portal) and it supports **monitor** mode
(raw 802.11 capture — the basis for logging client probe requests). Whether it
can do *both at once* is a separate question — that's §3.

---

## 3. Valid interface combinations — *the make-or-break section*

Supporting a mode isn't the same as supporting it *simultaneously* with another.
The combinations block is the authority:
```sh
/usr/sbin/iw phy phy0 info | grep -A8 'valid interface combinations'
```
This project's rt2800usb reports:
```
valid interface combinations:
   * #{ AP, mesh point } <= 8,
     total <= 8, #channels <= 1
```
How to read it:

- **`#{ AP, mesh point } <= 8`** — you may run up to **8 AP (or mesh) interfaces**
  at once. That's the hard ceiling on multi-SSID: 8 BSSes total (so 1 stable
  primary + up to **7 baits**).
- **`total <= 8`** — no more than 8 interfaces of *any* listed type together.
- **`#channels <= 1`** — every simultaneous interface must share **one channel**.
  No multi-channel operation; all your SSIDs live on the same channel.

**Critical gotcha for the KARMA / probe-sniffing idea:** this line lists only
`AP` and `mesh point`. **`monitor` is not in the combination**, which means this
driver will *not* let you run an AP and a monitor interface on the same radio at
the same time. To both serve the portal *and* sniff probes you'd need a
**second USB adapter** dedicated to monitor mode. A driver that *could* do both
would show something like `#{ AP } <= 1, #{ monitor } <= 1` as a valid combo.

> Rule of thumb: if two modes never appear in the *same* `* ...` combination
> line, you can't run them concurrently on that one radio.

---

## 4. Bands, channels, and rates — *where and how fast*

```sh
/usr/sbin/iw phy phy0 info | sed -n '/Band 1:/,/Band 2:/p'
```
Under each `Band` you'll see:
- **Frequencies** — the channels it can use, each annotated `(disabled)`,
  `(no IR)` = no initiating radiation / passive-scan only, or a power cap. Only
  channels without those flags are usable for an AP. rt2800usb here is a 2.4 GHz
  (Band 1) radio; pick 1/6/11 to avoid overlap.
- **Bitrates** — legacy rates. Real throughput comes from the HT/VHT lines.
- **HT/VHT/HE Capabilities** — 802.11n/ac/ax features (channel width, MCS,
  short GI). rt2800usb is 802.11n (HT) only — no VHT/HE.

Regulatory domain (which channels/powers are *legally* allowed) is separate:
```sh
/usr/sbin/iw reg get          # current reg domain; set via country_code in hostapd
```

---

## 5. What the radio is doing *right now*

Capabilities are `iw phy`; live state is `iw dev`:
```sh
/usr/sbin/iw dev                        # every interface, its type, channel, SSID
/usr/sbin/iw dev wlan0 info             # one interface: type (AP?), channel, txpower
/usr/sbin/iw dev wlan0 station dump     # associated clients + signal/bytes/time
/usr/sbin/iw dev wlan0 scan             # nearby APs (needs root; disrupts AP use)
```
`station dump` is exactly what the guestbook's `portal-stations.py` sidecar parses
for per-client signal and session stats.

Is it actually an AP?
```sh
/usr/sbin/iw dev wlan0 info | grep type      # expect: type AP
```

Radio soft/hard-blocked?
```sh
rfkill list
```

---

## 6. Quick-reference cheatsheet

| Question                          | Command                                                       |
| --------------------------------- | ------------------------------------------------------------- |
| Which driver?                     | `readlink -f /sys/class/net/wlan0/device/driver`              |
| Which radios?                     | `iw dev` or `ls /sys/class/ieee80211/`                        |
| What modes are supported?         | `iw phy phy0 info \| sed -n '/interface modes/,/Band/p'`      |
| How many APs / can it AP+monitor? | `iw phy phy0 info \| grep -A8 'valid interface combinations'` |
| Which channels/bands?             | `iw phy phy0 info \| sed -n '/Band 1:/,/Band 2:/p'`           |
| 11n/ac/ax?                        | `iw phy phy0 info \| grep -i 'HT\|VHT\|HE Capabilities'`      |
| What's live now?                  | `iw dev` / `iw dev wlan0 info`                                |
| Who's connected?                  | `iw dev wlan0 station dump`                                   |
| Legal channels?                   | `iw reg get`                                                  |
| Blocked?                          | `rfkill list`                                                 |

---

## 7. What this radio means for our features

From the rt2800usb output above:
- **Multi-SSID:** ✅ up to 8 BSSes, one channel → 1 primary + 7 baits. Matches
  `docs/multi-ssid.md`.
- **Monitor-mode probe logging / KARMA on this adapter:** ⚠️ not concurrently
  with the AP — `monitor` isn't in the valid combination with `AP`. Needs a
  **second USB Wi-Fi adapter** for the sniffing/response role while `wlan0`
  keeps serving the portal.
- **Band/PHY:** 2.4 GHz, 802.11n only. Fine for a captive portal; not a
  high-throughput link.
