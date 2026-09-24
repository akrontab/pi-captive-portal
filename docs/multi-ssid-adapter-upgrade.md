# TODO (later): real multi-SSID broadcast + bait rotation — needs a new Wi-Fi adapter

**Status:** deferred until a capable USB Wi-Fi adapter is on hand.

## Why the feature is parked

Field-tested 2026-09-13 on the live Pi. Findings:

- The host is a **Raspberry Pi 2 Model B** — it has **no built-in Wi-Fi**. The only
  radio is the USB **rt2800usb** adapter (`phy0`).
- `rt2800usb` advertises `#{AP,mesh} <= 8` interface *combinations*, so hostapd
  happily creates `wlan0_0..6` with correct block-aligned BSSIDs — **but the chip
  only ever beacons the first BSS.** The extra interfaces stay stuck in `type
  managed` / `DOWN` and never transmit. hostapd logs only `wlan0: AP-ENABLED`,
  never `wlan0_N: AP-ENABLED`, and no error.
- Confirmed three ways: hostapd journal (primary only), `iw dev` (secondaries
  `managed`/down), and an external Wi-Fi scan from another laptop (only `Portal`
  visible, zero baits).
- Separately, the rotation timer restarting hostapd every `SSID_ROTATE_INTERVAL`
  dropped **all** clients (including `Portal`) on every reshuffle — that was the
  "disconnects after a minute" symptom. Rotation is now off; portal is a single
  stable SSID.

**Conclusion:** multi-BSS beaconing is a hard limitation of this adapter. The
software (`ssid/portal-ssid-rotate.py`, `setup.sh` multi-SSID plumbing) is
essentially correct and should light up once the radio can actually beacon
secondary BSSes.

## Recommended adapters (Linux, actually beacon multi-BSS)

Top pick first. All use in-tree mainline drivers (no DKMS), 2.4 GHz is plenty for
a captive portal.

1. **Atheros AR9271 — `ath9k_htc`**  ⭐ recommended
   - Examples: **Alfa AWUS036NHA**, genuine **TP-Link TL-WN722N *v1*** (v2/v3
     switched to Realtek — avoid those).
   - 2.4 GHz, 802.11n. The gold standard for hostapd: rock-solid multi-BSS AP,
     supports several concurrent AP VIFs that *actually beacon*, plus monitor
     mode (bonus for the probe-sniffing/KARMA idea in `docs/radio-capabilities.md`).
     Low power draw — friendly to the Pi 2's current-limited USB. Needs the
     `firmware-atheros` package (usually already present).

2. **MediaTek MT7612U — `mt76x2u` (mt76 family)**
   - Examples: **Alfa AWUS036ACM**, generic MT7612U dongles.
   - Dual-band 2.4/5 GHz, 802.11ac, excellent mainline `mt76` multi-BSS AP
     support. More capable/higher throughput, but higher power draw — on a Pi 2
     use a **powered USB hub** (or `max_usb_current=1` in `config.txt`).

3. **Budget: MT7610U — `mt76x0u`** — cheap, mainline, multi-BSS capable. Fine if
   the AR9271 is unavailable.

**Avoid** for this: most Realtek dongles (rtl8188eu/8192cu/8812au/88x2bu) — they
need out-of-tree DKMS drivers and their multi-BSS AP support is inconsistent.
And of course the current `rt2800usb`.

### Verify a new adapter after plugging it in
```sh
readlink -f /sys/class/net/wlanX/device/driver | sed 's#.*/##'   # ath9k_htc / mt76x2u ...
/usr/sbin/iw phy phyN info | grep -A8 'valid interface combinations' # AP <= N
# The real test is that secondaries BEACON — reuse ssid/… or scan from another device.
```

## Implementation plan (when the adapter arrives)

The bait plumbing already exists; two architectures:

- **Simple:** move everything (Portal + baits) onto the capable adapter, one
  hostapd, multi-BSS. Caveat: hostapd has no runtime add/remove-BSS, so any
  reshuffle still restarts hostapd and briefly drops clients. Mitigate by
  rotating **rarely** (e.g. hourly) or not at all — baits are decoration and
  don't need to change during an event.

- **Best (two radios):** keep **`Portal` on one radio** and run the **baits as a
  separate hostapd instance on the *new* adapter**. Then reshuffling restarts
  only the bait instance — **`Portal` clients are never dropped.** This fully
  decouples the whimsy from portal stability.

- **Reuse the rt2800usb as a probe monitor (recommended combo):** the existing
  rt2800usb *does* support `monitor` mode (confirmed via `iw phy phy0 info`). It
  can't multi-BSS AP, but as a **dedicated monitor on its own radio** it's free
  to channel-hop the whole band (the `#channels<=1` limit only binds interfaces
  sharing one phy). So the ideal split is:
    - **rt2800usb → monitor**, hopping 1/6/11 (or all channels), harvesting probe
      requests band-wide.
    - **new adapter (AR9271) → multi-BSS AP** (`Portal` + rotating baits).
  This is the *only* workable split (rt2800usb can't be the AP) and beats
  one-radio AP+monitor, where the monitor would be stuck on the AP's channel.
  Pi 2 caveats: two USB Wi-Fi adapters need a **powered USB hub** (current
  limits), the USB 2.0 bus is shared with Ethernet, and interface names can swap
  on boot — pin them by MAC (systemd `.link`/udev) and set `WLAN_IF` to the AP.
  The monitor/probe-logging component is **now built** (`probe/portal-probe-logger.py`,
  tcpdump-based; OFF until the monitor radio exists) — see `docs/probe-logging.md`.
  For baits that mirror what clients probe for (dynamic KARMA) see `hostapd-mana`.
  Capability background: `docs/radio-capabilities.md`.

### Probe-listening (KARMA/MANA) + multi-SSID at the same time?

Two independent requirements decide whether one radio can sniff client probe
requests *and* run the AP:

1. **Concurrency:** the driver must list a *single* `valid interface
   combinations` line containing **both** `AP` and `monitor`. rt2800usb does not
   (monitor isn't in its AP combo). **AR9271 / `ath9k_htc` does** — it's the
   classic AP+monitor adapter.
2. **`#channels <= 1`:** while the radio runs the AP on one channel, a monitor
   vif on the *same* radio is locked to that channel — it can't hop. So
   single-adapter AP+monitor only captures probes on the portal's channel and
   misses most directed probes (clients spray them across all channels while
   scanning). Fine for on-channel traffic; not a full-band harvester.

**Recommended for real probe logging: two adapters.** Adapter A = multi-BSS AP
pinned to the portal channel; Adapter B = dedicated monitor, free to channel-hop
1/6/11 (or the whole band). This is what Kismet/airodump and the WiFi Pineapple
do, and what `hostapd-mana`/`hostapd-wpe` expect (they can auto-broadcast the
SSIDs seen in probes — *dynamic* KARMA — instead of a fixed bait list). AR9271 is
great for either role, so two AR9271s is a clean combo (or AR9271 for AP +
MT7612U for monitor). Verify a candidate with:
`iw phy phyN info | grep -A15 'valid interface combinations'` — need one line
with both `AP` and `monitor`.

Also fix regardless of adapter:
- **Orphan-interface teardown:** ✅ **DONE (2026-09-24).** `portal-ssid-rotate.py`
  gained `cleanup_secondaries()` (deletes every `wlan0_N` VIF via `iw dev … del`)
  — called before each rotation restart, and exposed as `--cleanup-only`, which
  `setup.sh` wires into a hostapd `ExecStartPre` drop-in
  (`/etc/systemd/system/hostapd.service.d/portal-cleanup.conf`) so cold starts
  reap orphans too. No more ifindex climb across restarts.
- **Rotation interval:** ✅ **DONE (2026-09-24).** Default moved `2min → 1h`
  everywhere (`setup.sh`, `portal.env.example`, the timer unit), with the
  restart-drops-all-clients cost documented inline at each spot. hostapd has no
  runtime add/remove-BSS, so restart-based rotation is inherently client-dropping
  — rotate rarely, or (with two radios) rotate only the bait instance.

See also: `docs/multi-ssid.md`, `docs/radio-capabilities.md`.
