# Session 5a: Break-It Exercises

The goal of these exercises is to deepen your understanding by
**deliberately breaking** something and observing what happens.
Each exercise has a hypothesis ("if I break X, then Y will happen")
and a verification step.

## Exercise 1: Mismatched L3VNI numbers

What happens if leaf1 and leaf2 disagree on which L3VNI carries
Tenant-B?

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
vrf context Tenant-B
no vni 50002
vni 50003
end
```

**Hypothesis**: Cross-leaf routing for Tenant-B will break because
the leaves can't agree on which L3VNI to use for encapsulation.

**Verify the break**: Ping host2 from leaf1's perspective, or any
Tenant-B routing attempt. EVPN Type-5 routes will be there but
the L3VNI on the receiving leaf doesn't match what was advertised.

```
show bgp l2vpn evpn route-type 5
```

You may also see error messages in `show logging` about VNI
mismatches.

**Restore**:
```
configure terminal
vrf context Tenant-B
no vni 50003
vni 50002
end
```

**Lesson**: L3VNI mapping must be consistent across all leaves
participating in the VRF. Production fabrics manage this via
automation/templating.

## Exercise 2: Remove anycast mode from one leaf's Tenant-B SVI

What if only one leaf has anycast mode enabled?

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface Vlan30
no fabric forwarding mode anycast-gateway
end
```

**Hypothesis**: host2 might still ping its own gateway (leaf2's SVI),
but the gateway is no longer behaving as an anycast endpoint.
Migration of host2 to leaf1 would break.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 10.200.10.1
```

Should still work (local SVI exists). But examine:

```
show interface vlan 30 | include "MAC"
```

The leaf2 SVI now uses its own MAC, not the anycast MAC.

**Restore**:
```
configure terminal
interface Vlan30
fabric forwarding mode anycast-gateway
end
```

**Lesson**: Anycast gateway is per-SVI-per-leaf. If you forget it
on one leaf, that VRF loses anycast behavior on that leaf.

## Exercise 3: Try to violate isolation manually

Can you reach Tenant-B from Tenant-A via static routes only?

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
vrf context Tenant-A
ip route 10.200.10.0/24 vrf Tenant-B
end
```

This uses NX-OS's inter-VRF static route capability.

**Hypothesis**: This adds a route in Tenant-A's table pointing at
Tenant-B's VRF. Should host1 now ping host2?

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

The answer depends on whether the static gets a usable next-hop.
Likely: ping succeeds going **out** (Tenant-A's table now has the
route), but the reply fails because Tenant-B doesn't have a route
back to 10.100.10.0/24. Half-leak.

**Verify the asymmetry**:
```
show ip route vrf Tenant-A 10.200.10.0
show ip route vrf Tenant-B 10.100.10.0
```

One direction works, the other doesn't.

**Restore**:
```
configure terminal
vrf context Tenant-A
no ip route 10.200.10.0/24 vrf Tenant-B
end
```

**Lesson**: Asymmetric leaks cause connectivity to be half-broken
in confusing ways. Production VRF leaking should always be
considered for **both** directions, or one-way intentionally with
SNAT for return traffic.

## Exercise 4: Shutdown a leaf's NVE — what survives?

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface nve1
shutdown
end
```

**Hypothesis**: All VXLAN encapsulation on leaf2 stops. host2 loses
all cross-leaf connectivity but can still ping its local gateway.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host2 ping -c 2 10.200.10.1  # local SVI, should work
docker exec clab-vxlan-evpn-host2 ping -c 2 10.200.10.11 # would fail if any other host existed in same subnet on remote leaf
```

```
show nve interface
show nve peers
```

**Restore**:
```
configure terminal
interface nve1
no shutdown
end
```

**Lesson**: The NVE is the VTEP — shutting it isolates a leaf from
the VXLAN fabric while preserving its local L2/L3 functions.

## Skip this section if short on time

The Session 5a verification is the main learning. Break-it is
optional — come back to these when you want to deepen confidence.
