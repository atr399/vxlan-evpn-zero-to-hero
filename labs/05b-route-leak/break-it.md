# Session 5b: Break-It Exercises

## Exercise 1: One-way leak — see asymmetric routing fail

Remove the import on Tenant-B but keep it on Tenant-A:

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
vrf context Tenant-B
no route-target import 65000:50001
no route-target import 65000:50001 evpn
end
```

Repeat on leaf2.

**Hypothesis**: host1 can route TO host2 (Tenant-A still imports
Tenant-B's RT, so it knows the way), but host2's reply has no
route back. Result: one-way connectivity that fails ICMP because
echo-reply needs to come back.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
```

Expected: 100% packet loss. Looks like total failure — but really
the request reaches host2; only the reply is dropped.

To prove it, check arp on host2 after the failed ping:

```bash
docker exec clab-vxlan-evpn-host2 arp -n
```

(if anything appears it'd be the gateway MAC — host2 may not even
ARP for the source if it has no route).

**Restore**:
```
configure terminal
vrf context Tenant-B
route-target import 65000:50001
route-target import 65000:50001 evpn
end
```

**Lesson**: Asymmetric leaks are a common production pattern
(shared services). They require SNAT or proxy at the boundary so
the return traffic always has a known path. Pure VRF route leak
alone isn't enough for asymmetric.

## Exercise 2: Wrong RT in import line

```
configure terminal
vrf context Tenant-A
no route-target import 65000:50002
route-target import 65000:50003
end
```

(Notice: 50003 instead of 50002. Tenant-B's L3VNI is actually
50002, not 50003.)

**Hypothesis**: No routes get imported because no EVPN routes
exist with the RT 65000:50003. The leak is configured but
effectively does nothing.

**Verify**:
```
show ip route vrf Tenant-A | include "10.200"
```

Expected: nothing. Tenant-A doesn't see Tenant-B's routes.

```
show bgp ipv4 unicast vrf Tenant-A
```

Tenant-B's prefixes are not present in the BGP table.

**Restore**:
```
configure terminal
vrf context Tenant-A
no route-target import 65000:50003
route-target import 65000:50002
end
```

**Lesson**: RT typos are the most common reason "configured leak
doesn't work in production." Always double-check the L3VNI's RT
before configuring the import in the other VRF.

## Exercise 3: What does a route with no path look like?

If we leak the route but the underlay is broken, traffic still
fails. Disable leaf2's link to spine1:

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface Ethernet1/1
shutdown
end
```

leaf2 still has one path to the rest via spine2.

```
ssh admin@clab-vxlan-evpn-leaf1
show ip route vrf Tenant-A 10.200.10.0/24
```

Should still resolve via 10.0.1.22 (leaf2's VTEP). The remote
next-hop is the VTEP, not the spine.

Now also shut leaf2's link to spine2:

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface Ethernet1/2
shutdown
end
```

leaf2 is now disconnected from the fabric.

**Hypothesis**: leaf1 still has the BGP route to 10.0.1.22 (the
EVPN Type-5 hasn't been withdrawn yet — BGP holdtimes apply),
but the underlay (OSPF) has lost reachability.

```
ssh admin@clab-vxlan-evpn-leaf1
show ip route 10.0.1.22
```

Likely: route not found (OSPF withdrew it within ~40 sec). The
EVPN Type-5 entry now points at an unreachable next-hop —
**unresolved**, marked accordingly.

```
show bgp ipv4 unicast vrf Tenant-A
```

The Tenant-B entries should be marked as not-best because the
next-hop is unresolved.

**Restore**:
```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface Ethernet1/1
no shutdown
interface Ethernet1/2
no shutdown
end
```

Wait ~30 sec for protocols to reconverge.

**Lesson**: VRF leaks operate on the control plane. The data
plane still requires underlay reachability. A perfectly leaked
RT does nothing if the VTEP is unreachable.

## Skip if short on time

These three exercises probe the boundaries of route leaking. They
won't be needed if everything in the verify.md passed cleanly.
Worth returning to when you want to demonstrate "why VRF leaks
fail in production" to colleagues.
