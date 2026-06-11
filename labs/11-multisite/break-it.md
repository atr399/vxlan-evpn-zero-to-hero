# Session 11 — Break It On Purpose

Multi-Site has a lot of moving parts, and the instructive failures are
the ones where **the control plane stays up while the data plane dies**.
Each exercise breaks one thing, shows you the symptom, and ties it back
to the concept. Restore after each before moving to the next.

Run `show` commands via `ssh admin@clab-vxlan-evpn-<node>` (password
`admin`). Have a known-good lab first — see `verify.md`.

---

## 1. Kill the underlay across the DCI

**Break it.** On **spine1**, remove OSPF from the DCI link:

```
configure terminal
interface Ethernet1/3
  no ip router ospf UNDERLAY area 0.0.0.0
end
```

**Observe.**

```
show ip route 10.0.2.200          (on spine1)   → Route not found (eventually)
show bgp l2vpn evpn summary       (on spine1)   → DCI neighbor STILL Established
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10   → 100% loss
```

**Teaching point.** The eBGP-EVPN session survives (it's sourced from a
directly-connected interface, not the loopback you just made
unreachable), so the **control plane looks healthy** — routes are still
exchanged. But the cross-site route's next-hop (the far BGW's VIP) is no
longer reachable, so the VXLAN tunnel can't form and traffic
black-holes. This is Lesson #1 from the build, reproduced on demand:
*EVPN gives you the route; the underlay still has to give you a path to
the next-hop.*

**Restore.**

```
configure terminal
interface Ethernet1/3
  ip router ospf UNDERLAY area 0.0.0.0
  ip ospf network point-to-point
end
```

Give OSPF ~30 s, confirm `show ip route 10.0.2.200` returns, retest the
ping.

---

## 2. Remove the RT-ASN rewrite on the DCI

**Break it.** On **spine1**:

```
configure terminal
router bgp 65000
  neighbor 192.168.100.1
    address-family l2vpn evpn
      no rewrite-evpn-rt-asn
end
clear bgp l2vpn evpn *
```

**Observe.**

```
show ip route 10.100.30.0/24 vrf Tenant-A   (on leaf1)   → route disappears
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10   → 100% loss
```

**Teaching point.** Routes cross the DCI carrying RTs derived from the
*sending* site's ASN (`65001:50001` from Site 2). Without
`rewrite-evpn-rt-asn`, Site 1 expects `65000:50001` and never imports the
route into Tenant-A. The route is *received* by BGP but not *imported* by
the VRF — a different failure from #1 (there the route imported but the
next-hop was unreachable; here the route never makes it into the VRF at
all). Two different "ping fails" with two different root causes.

**Restore.** Put `rewrite-evpn-rt-asn` back under the neighbor's
`address-family l2vpn evpn`, then `clear bgp l2vpn evpn *`.

---

## 3. Take down the DCI link entirely

**Break it.** From the VM host (not inside a node):

```bash
docker exec clab-vxlan-evpn-spine1 \
  sshpass 2>/dev/null   # (no-op guard)
```

Instead, shut the interface on spine1:

```
configure terminal
interface Ethernet1/3
  shutdown
end
```

**Observe.**

```
show bgp l2vpn evpn summary   (on spine1)   → 192.168.100.1 drops to Idle/Active
show nve peers                (on leaf1)    → 10.0.1.15 (Site 2 VTEP) ages out
docker exec clab-vxlan-evpn-host5 ping -c 3 10.100.10.10   → 100% loss
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10   → STILL WORKS
```

**Teaching point.** The DCI is the *only* path between sites — lose it and
all cross-site traffic stops, but **each site keeps working internally**.
That intra-site survival is the fault isolation Multi-Site is designed
for: a total inter-site failure doesn't take down either fabric. In
production you'd run redundant DCI links (and peer the eBGP-EVPN session
on loopbacks with multihop) so a single link loss doesn't sever the
sites.

**Restore.** `no shutdown` on Eth1/3, wait for OSPF + eBGP-EVPN to
re-establish (~30–45 s), retest.

---

## 4. Remove the next-hop rewrite route-map ⭐

The most instructive break — it reproduces the exact bug that made this
session hard.

**Break it.** On **spine1**, detach the route-map from the leaf sessions:

```
configure terminal
router bgp 65000
  neighbor 10.0.0.21
    address-family l2vpn evpn
      no route-map SET-NH-VIP out
  neighbor 10.0.0.22
    address-family l2vpn evpn
      no route-map SET-NH-VIP out
end
clear bgp l2vpn evpn *
```

**Observe.** On **leaf1**:

```
show ip route 10.100.30.0/24 vrf Tenant-A
```

The next-hop flips from `10.0.2.100` back to `192.168.100.1` (the DCI
interface IP).

```
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10   → 100% loss
```

**Teaching point.** The leaf now has a route to the Site 2 subnet, the RT
is correct, the BGP session is healthy — and it *still* fails, because the
next-hop (`192.168.100.1`) is a routed-link IP, not a VTEP. The leaf
can't build a VXLAN tunnel to it. On real hardware the BGW rewrites this
to its VIP automatically; in this image we force it with the
`SET-NH-VIP` route-map. This is the crux of the whole session: **the
cross-site route's next-hop must be a real VTEP the fabric can tunnel
to** (Lesson #3 in `docs/11-multisite.md`).

**Restore.**

```
configure terminal
router bgp 65000
  neighbor 10.0.0.21
    address-family l2vpn evpn
      route-map SET-NH-VIP out
  neighbor 10.0.0.22
    address-family l2vpn evpn
      route-map SET-NH-VIP out
end
clear bgp l2vpn evpn *
```

Confirm Test 5 in `verify.md` shows `*via 10.0.2.100` again, retest the
ping.

---

## 5. Shut a single Site 1 spine uplink (fault-tolerance within a site)

**Break it.** leaf1 has uplinks to spine1 only in this slim topology, so
instead exercise the vPC pair: stop leaf1 entirely and confirm host1
survives via leaf2.

```bash
docker stop clab-vxlan-evpn-leaf1
```

**Observe.**

```bash
# host1 is vPC-bonded across leaf1+leaf2; cross-site should recover via leaf2
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.30.10
```

Expect 1–2 lost packets during reconvergence, then success — host1's bond
fails over to leaf2, and leaf2 still reaches Site 2 via spine1's BGW.

**Teaching point.** vPC (Session 6) and Multi-Site compose cleanly: a
leaf failure inside Site 1 is absorbed by the vPC pair, and the
cross-site path is unaffected because it depends on the spine/BGW, not on
which leaf the host is using.

**Restore.**

```bash
docker start clab-vxlan-evpn-leaf1
```

Wait for it to pass healthcheck (~8–12 min for N9000v), then re-push its
config if needed:

```bash
./scripts/switch.sh 11-multisite
```

> Reminder: single-node `docker start` of an N9000v can be slow or
> occasionally wedge. If leaf1 doesn't recover cleanly, the reliable path
> is a full `reset.sh 11-multisite` + `deploy-final.sh`.

---

## What these failures teach, together

| Break | Control plane | Data plane | Root cause |
|-------|---------------|------------|------------|
| 1. No OSPF on DCI | up | down | next-hop unreachable in underlay |
| 2. No RT rewrite | up | down | route not imported into VRF |
| 3. DCI link down | DCI down | cross-site down, intra-site **up** | only inter-site path lost |
| 4. No NH rewrite | up | down | next-hop isn't a real VTEP |
| 5. Leaf down | up | recovers via vPC | local redundancy absorbs it |

The recurring theme — breaks 1, 2, and 4 — is that **a healthy BGP
session is not a working data plane**. Multi-Site troubleshooting starts
at the cross-site route's next-hop: is it present, is it the BGW VIP, and
is that VIP reachable in the underlay?
