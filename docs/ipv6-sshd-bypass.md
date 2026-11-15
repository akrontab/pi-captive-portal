# IPv6 → sshd bypass (and the fix)

> **Status: FIXED** in `setup.sh` / `config/10-wlan0-portal.network.tmpl`. This
> write-up is the record of the bug, why it worked, and a *lite* PoC to start
> exploring it on a rig that is **missing the fix** (or to confirm the fix holds).
> Only run this against your own Pi.

## TL;DR

The host firewall was **IPv4-only**. `wlan0` (the hostile client radio) still got
an IPv6 **link-local** address from systemd-networkd, and `sshd` listens on IPv6
as well as IPv4. So a client on the portal Wi-Fi could reach **port 22 over IPv6**
even though every IPv4 path to `22` was dropped — defeating the "SSH is only
reachable over the wired interface" guarantee.

Key auth still stood in the way (password auth is off), so this was **exposure of
the management plane**, not an instant shell. But it put `sshd` — a large, juicy
attack surface, and the gateway to the passwordless-sudo `pi` account — in front
of every person in radio range. That is exactly what the firewall was meant to
prevent.

## Why it worked

Four facts line up:

1. **The firewall only ever spoke IPv4.** `configure_firewall` wrote
   `/etc/iptables/rules.v4` and ran `iptables-restore`. There was no
   `ip6tables` ruleset at all, so the IPv6 `INPUT` policy was the default
   `ACCEPT`.
2. **`wlan0` had an IPv6 address.** systemd-networkd assigns every managed link
   an `fe80::/64` link-local address unless told not to. Link-local needs no
   router, no RA, no DHCPv6 — it exists the moment the interface is up.
3. **`sshd` binds `::` by default.** On a dual-stack host that single socket
   accepts v4 *and* v6 connections. Nothing pinned it to the wired address.
4. **The client shares the link.** Anyone associated to the AP is on the same
   L2 segment as `wlan0`, so the Pi's link-local address is directly reachable
   from the client — scoped to that interface (`%ifname`).

IPv4 was locked (`-A INPUT -i wlan0 ... DROP`); IPv6 was wide open. The attacker
just had to speak the other protocol.

## Lite PoC — from a client joined to the portal Wi-Fi

Join `Portal` (the SSID) first. All of this runs on the **client**, not the Pi.
Nothing here is destructive — it only proves the port is reachable.

```bash
# 1. Which interface am I on the portal with? (has a 192.168.4.x address)
ip -4 addr | grep 192.168.4
IFACE=wlan0            # <- your client's Wi-Fi interface name

# 2. Discover link-local neighbours on that segment. The all-nodes multicast
#    ping makes every host on the link answer; the Pi is one of them.
ping6 -c3 ff02::1%$IFACE
ip -6 neigh show dev $IFACE          # harvest fe80:: addrs that replied

# 3. For each fe80:: candidate, is TCP/22 open over v6? (the bug: it is)
#    Scope the address to your interface with %IFACE.
PI6=fe80::XXXX:XXXX:XXXX:XXXX         # <- a neighbour from step 2
nc -6 -vz -w2 "$PI6%$IFACE" 22        # "succeeded" / "open" == bypass present

# 4. Confirm it's really sshd and really the Pi (banner grab, still no creds):
ssh -6 -o StrictHostKeyChecking=no -o PreferredAuthentications=none \
    -o ConnectTimeout=3 "pi@$PI6%$IFACE"
#   You'll be refused for auth (key-only) — but reaching the SSH *banner* from
#   the client proves 22 is exposed over v6. On the fixed rig this hangs/resets.
```

What each step shows:
- **Step 2** — the Pi answers multicast on the portal segment; you now have its
  `fe80::` address without any cooperation from it.
- **Step 3** — `nc` reports the port **open** on a vulnerable rig. This is the
  whole bug in one line.
- **Step 4** — the SSH banner (`SSH-2.0-OpenSSH_...`) coming back to a portal
  client is the finding. Auth failing afterwards is expected and not a mitigation
  you should rely on.

### Fingerprint-level next steps (left as exploration)

Once `22/tcp6` is reachable you'd normally pivot to: enumerating the sshd version
for known CVEs, pre-auth resource abuse, key-type/algorithm negotiation probing, and
checking whether any *other* service also binds `::` (the same bug exposes them
all at once — re-run step 3 against `80`, `8080`, `5353`, etc.). None of that is
scripted here on purpose; the point of the PoC is to detect the exposure.

## The fix

Two independent layers, so one failing doesn't reopen the hole:

1. **No v6 address on the AP radio** —
   `config/10-wlan0-portal.network.tmpl`:
   ```ini
   LinkLocalAddressing=no
   IPv6AcceptRA=no
   ```
   With no `fe80::` on `wlan0`, there is nothing for a client to connect *to*
   over v6. (This is the real cure — the portal is IPv4-only by design.)

2. **`ip6tables` backstop** — `configure_firewall` now also writes
   `/etc/iptables/rules.v6` mirroring the v4 policy: allow
   loopback/return/ICMPv6/DHCPv6/DNS/HTTP on `wlan0`, **drop everything else,
   `22` included**. So even if a v6 address reappeared (a config regression, a
   future RA, a second tool bringing the interface up), port 22 stays dropped.

`net.ipv6.conf.all.forwarding` is also pinned to `0`, matching the v4 side.

## Verify the fix on the Pi

```bash
ip -6 addr show wlan0                 # expect: NO inet6 fe80:: line
ss -tlnp | grep ':22'                 # sshd may still bind :: globally — that's
                                      # fine; the firewall + no-address stop wlan0
sudo ip6tables -S | grep -E 'wlan0'   # expect the allow list + a final DROP
```

Then re-run the **client-side PoC** above: step 2 should find no Pi link-local,
and step 3/4 should fail to connect. If `nc` still says *open*, the fix didn't
take — check that the `.network` drop-in is in place and `wlan0` was re-cycled.

## Lesson

A dual-stack host needs a **dual-stack firewall**. An interface-scoped IPv4
`DROP` is only half a rule: IPv6 is a second, independent path to every listener,
and "we don't use IPv6" is not the same as "IPv6 is turned off." Deny the
address *and* filter the protocol.
