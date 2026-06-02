# Session 7: Break-It Exercises

## Exercise 1: Remove `rewrite-evpn-rt-asn` on one spine

The single most important config in Session 7. Watch what happens
without it.

```
ssh admin@clab-vxlan-evpn-spine1
configure terminal
router bgp 65001
  neighbor 10.10.1.1
    address-family l2vpn evpn
      no rewrite-evpn-rt-asn
  neighbor 10.10.2.1
    address-family l2vpn evpn
      no rewrite-evpn-rt-asn
end
clear ip bgp 10.10.1.1 soft out
clear ip bgp 10.10.2.1 soft out
```

**Hypothesis**: Without RT rewriting on spine1, routes traveling
spine1 → leaf2 will carry the original leaf1-side RT (65000:VNI).
Wait — that's actually what we want. So why do we need rewrite?

**Look more carefully**:
```
show bgp l2vpn evpn route-type 2
```

Look at the RT in the extended community on routes received from
spine1. With our explicit `route-target import/export 65000:VNI`,
the RT is hardcoded to 65000:VNI regardless of local ASN.

**So why does `rewrite-evpn-rt-asn` matter?** It matters when RTs
are **auto-generated** (`route-target both auto`), which derives
RT from local ASN. In our config we hardcoded 65000:VNI everywhere,
so we don't strictly need the rewrite.

**But there's a deeper issue**: NX-OS's eBGP-EVPN may still apply
ASN rewriting to certain extended community formats even with
explicit RTs. The `rewrite-evpn-rt-asn` config is **defensive** —
ensures the spine handles all RT formats correctly across the ASN
boundary.

**Restore**:
```
configure terminal
router bgp 65001
  neighbor 10.10.1.1
    address-family l2vpn evpn
      rewrite-evpn-rt-asn
  neighbor 10.10.2.1
    address-family l2vpn evpn
      rewrite-evpn-rt-asn
end
```

**Lesson**: In a real production fabric with explicit RTs (our
pattern), the rewrite is defensive. With auto RTs (default), the
rewrite is **mandatory** — without it, routes can't cross the
ASN boundary at all because each side derives a different RT
from its local ASN.

## Exercise 2: Remove `allowas-in` on leaves

What if leaves don't allow their own ASN in received routes?

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
router bgp 65011
  neighbor 10.10.1.0
    address-family l2vpn evpn
      no allowas-in 1
  neighbor 10.10.3.0
    address-family l2vpn evpn
      no allowas-in 1
end
clear ip bgp 10.10.1.0 soft in
clear ip bgp 10.10.3.0 soft in
```

**Hypothesis**: leaf1 will reject any EVPN route originating from
leaf2 (which is also AS 65011). The route arrives at leaf1 with
AS-path `65001 65011` (spine1 → originally from leaf2 in 65011),
and BGP loop prevention drops it.

**Verify**:
```
show bgp l2vpn evpn route-type 2
```

Should now MISSING all routes originating from leaf2. Only leaf1's
own routes visible.

```
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: 100% loss. host2's MAC isn't learned by leaf1 because
the EVPN route was dropped at BGP import.

**Restore**:
```
configure terminal
router bgp 65011
  neighbor 10.10.1.0
    address-family l2vpn evpn
      allowas-in 1
  neighbor 10.10.3.0
    address-family l2vpn evpn
      allowas-in 1
end
clear ip bgp 10.10.1.0 soft in
clear ip bgp 10.10.3.0 soft in
```

**Lesson**: When vPC peers share an ASN within an otherwise per-
device-ASN fabric, `allowas-in` is required for the leaves to
learn each other's routes via the spines. Hyperscalers without
vPC don't need this because every device has a unique ASN.

## Exercise 3: Disable ECMP — set maximum-paths 1

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
router bgp 65011
  address-family ipv4 unicast
    no maximum-paths 2
  address-family l2vpn evpn
    no maximum-paths 2
end
clear ip bgp *
```

**Hypothesis**: leaf1 only uses ONE spine instead of both for
underlay routes. Traffic to remote VTEPs goes through that one
spine only. If that spine fails, convergence is needed before
recovery.

**Verify**:
```
show ip route 10.0.0.22
```

Expected: only ONE path now (via either spine1 or spine2, not
both).

Traffic still works (single-path is fine for connectivity), but
no load-balancing.

**Restore**:
```
configure terminal
router bgp 65011
  address-family ipv4 unicast
    maximum-paths 2
  address-family l2vpn evpn
    maximum-paths 2
end
```

**Lesson**: ECMP is mandatory for fabric scaling. Without
`maximum-paths`, BGP picks one path and ignores the others.
Production hyperscale fabrics use `maximum-paths 64` to use all
available spines.

## Exercise 4: Spine failure with eBGP underlay

```bash
ssh admin@clab-vxlan-evpn-spine1
configure terminal
interface Ethernet1/1
shutdown
interface Ethernet1/2
shutdown
end
```

(Shuts spine1's leaf-facing interfaces — effectively kills spine1
from the leaves' perspective without losing the container.)

In another terminal, run continuous ping:
```bash
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

**Hypothesis**: BGP detects the session timeout on the now-down
spine, withdraws paths through it. Since `maximum-paths 2` was
already using both spines, traffic shifts to spine2 with minimal
loss.

**Without BFD**: BGP timeout is the default ~180 seconds (hold
timer). Expect significant packet loss until hold timer expires.

**With BFD** (we skipped in Session 7): convergence would be
sub-second.

**Verify**:
```
show ip route 10.0.0.22
```

Eventually shows only one path (via spine2). Takes ~3 minutes
without BFD.

**Restore**:
```
configure terminal
interface Ethernet1/1
no shutdown
interface Ethernet1/2
no shutdown
end
```

**Lesson**: The default BGP timers are too slow for data center
convergence. **BFD is essential in production** — sub-second
detection and convergence. We deferred BFD to a future session
but it's the most important production add-on for eBGP underlay.

## Skip if short on time

Exercise 1 (rewrite-evpn-rt-asn) is the educational keystone. The
others are detail. Exercise 4 (spine failure with slow convergence)
is the motivation for BFD in production.
