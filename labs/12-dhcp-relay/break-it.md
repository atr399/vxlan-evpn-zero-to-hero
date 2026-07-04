# Session 12 — Break It On Purpose

DHCP relay on an anycast fabric has three classic failure modes, and all
three produce the same surface symptom — "the host didn't get an
address" — with three completely different root causes. Learning to tell
them apart is the whole point.

`show` on Nexus via `ssh admin@clab-vxlan-evpn-<node>` (password
`admin`). Start from a known-good lab (see `verify.md`). After each
break, re-test with:

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n -t 3'
```

---

## 1. Relay loopback not advertised into the tenant VRF

**Break it.** On **leaf1**, pull the relay loopback out of the VRF's
advertised routes by shutting it:

```
configure terminal
interface loopback99
  shutdown
end
```

**Observe.** The client's DHCPDISCOVER still leaves leaf1 (you'll see it
in the server log), but no lease arrives:

```bash
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread | grep -i dhcp | tail -5'
# DISCOVER seen, OFFER sent... but client never gets it
docker exec clab-vxlan-evpn-host1 ip addr show eth1   # no 10.100.10.x
```

**Teaching point.** The request reaches the server (forward path uses
the L3Out, which works). But the server addresses its OFFER to the
`giaddr` — `10.99.0.21` — and if that loopback isn't reachable back
across the fabric, the reply black-holes. **Classic one-way DHCP
failure: discover works, offer never returns.** When DHCP "half works,"
suspect the return path to the giaddr first.

**Restore.** `no shutdown` on `loopback99`, confirm
`show bgp l2vpn evpn | include 10.99.0.21` returns, re-test.

---

## 2. Relay loopback inside the DHCP scope ⭐

The subtle, real-world one.

**Break it.** Re-address `loopback99` so it falls *inside* the client
scope the server hands out:

```
configure terminal
interface loopback99
  ip address 10.100.10.150/32      ! INSIDE the 10.100.10.100-200 pool
end
```

(Also point the SVI relay source at the new address if needed; the lab's
config keys off `loopback99` so the change is picked up.)

**Observe.** Leases may still be handed out — but now the server's pool
includes `10.100.10.150`, which is *also* leaf1's giaddr. Eventually a
client is offered `.150`, or the server's own reply path to the giaddr
collides with a leased host:

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
# intermittent: sometimes works, sometimes duplicate-address / no-reply
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread | grep -i "in use\|declined\|10.100.10.150" | tail'
```

**Teaching point.** The relay loopback is *infrastructure*, not a client
address — but nothing stops you putting it inside a pool, and the
failure is intermittent and points everywhere except the real cause.
This is why production keeps relay/giaddr loopbacks in a dedicated block
(`10.99.0.0/24` here) provably disjoint from every client scope. When
DHCP failures are *intermittent* rather than total, suspect an address
overlap.

**Restore.** Put `loopback99` back to `10.99.0.21/32`, re-test until
stable.

---

## 3. Server ignores Option 82 link-selection

**Break it.** Reconfigure dnsmasq to key its scope on `giaddr` instead
of the link-selection sub-option (i.e. behave like a dumb server):

```bash
docker exec clab-vxlan-evpn-dhcp-server sh -c '
  pkill dnsmasq
  cat > /etc/dnsmasq-bad.conf << EOF
port=0
dhcp-relay=10.99.99.10
# NO link-selection awareness — single flat scope on the giaddr subnet:
dhcp-range=10.99.0.1,10.99.0.250,255.255.255.0,12h
log-dhcp
EOF
  dnsmasq -C /etc/dnsmasq-bad.conf -d &
'
```

**Observe.**

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
docker exec clab-vxlan-evpn-host1 ip addr show eth1
```

The client gets an address from `10.99.0.0/24` — the *giaddr's* subnet —
which is wrong: that's the relay loopback range, not VLAN 10. The host
is unusable (wrong subnet, wrong gateway).

**Teaching point.** On an anycast fabric the `giaddr` is deliberately
*not* the client's subnet — it's the unique relay loopback. A server
that selects scope from `giaddr` (the classic assumption) assigns from
the wrong network entirely. The relay did everything right; the server
must understand Option 82 **link-selection** to pick the client's real
subnet. This is why "is your IPAM Option-82-aware?" is a real
pre-deployment question.

**Restore.** Restart dnsmasq with the correct config from `verify.md` /
the bring-up, re-test.

---

## 4. Relay address missing on the SVI

**Break it.** On **leaf1**, remove the relay target from VLAN 10:

```
configure terminal
interface Vlan10
  no ip dhcp relay address 10.99.99.10
end
```

**Observe.**

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n -t 3'
# total failure - no DISCOVER reaches the server at all
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread | grep -i dhcp | tail -3'
# nothing new from this client
```

**Teaching point.** Without a relay address, the client's broadcast dies
at the leaf — it's never unicast to the server. This is *total* failure
(no server-side log at all), which distinguishes it from #1 (server sees
discover, reply lost) and #3 (server replies, wrong subnet). **The
server-side log is your fork in the road:** nothing logged → forward
path / relay-address problem; discover-but-no-lease → return path;
lease-in-wrong-subnet → Option 82 / scope problem.

**Restore.** Re-add `ip dhcp relay address 10.99.99.10` under
`interface Vlan10`.

---

## What these failures teach, together

| Break | Client result | Server log | Root cause |
|-------|---------------|-----------|------------|
| 1. loopback not in VRF | discover ok, no lease | DISCOVER + OFFER | reply can't route to giaddr |
| 2. loopback in scope | intermittent | conflicts / declines | giaddr overlaps a client address |
| 3. server ignores Opt82 | lease in wrong subnet | DORA on giaddr subnet | scope keyed on giaddr not link-selection |
| 4. no relay address | total failure | nothing | broadcast never relayed |

The throughline: **"no DHCP" has four different fixes, and the
server-side log tells you which one.** Nothing logged → forward path.
Offer-but-no-lease → return path to giaddr. Wrong subnet → Option 82.
That triage is the real production skill this session teaches.
