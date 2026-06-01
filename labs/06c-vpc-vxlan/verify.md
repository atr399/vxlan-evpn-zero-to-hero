# Session 6c: Verification — Shared VTEP for vPC + VXLAN

**What 6c achieves**: The vPC pair (leaf1+leaf2) advertises EVPN
routes via a **single shared VTEP IP** (10.0.1.100) instead of
each leaf advertising its own loopback1. Remote leaves see "the
vPC pair" as one VTEP — letting them load-balance traffic between
leaf1 and leaf2.

**This is also the fix for the consistency failure** discovered
during 6b deployment. Without the secondary IP, vPC's consistency
check fails when any vPC member port is active.

## Pre-check: 6b is regressed

If you came from 6c via `switch.sh 06b-vpc-host-bond`, vPC should
be in the failed-consistency state (no secondary IP yet). Confirm:

```
ssh admin@clab-vxlan-evpn-leaf1
show vpc
```

Expected (the broken state):
```
Configuration consistency status  : failed
Configuration inconsistency reason: Secondary IP address does not match
vPC 10: status down*
```

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: 100% loss. The bond exists but vPC won't forward.

**This is the deliberately broken state.** 6c is what fixes it.

## Step 1: Apply 6c

```bash
./scripts/switch.sh 06c-vpc-vxlan
```

Expected: ~10 sec, "Config OK on leaf1 (found: 10.0.1.100 secondary)"

The push adds a single line to each leaf's loopback1: 
`ip address 10.0.1.100/32 secondary`. NX-OS detects the matching
secondary IP on both leaves and concludes "this is a vPC VIP."

Wait ~15 seconds for OSPF to advertise the new loopback IP and
NVE to re-initialize.

## Check 1: vPC consistency is now success

```
show vpc
```

Expected:
```
Configuration consistency status  : success
Number of vPCs configured         : 1

vPC status
Id    Port          Status Consistency Reason                Active vlans
10    Po10          up     success     success               10
```

If still `failed`, OSPF may not have advertised the secondary IP
yet. Wait 30 more seconds.

## Check 2: NVE recognizes vPC pairing

```
show nve interface nve1 detail
```

Look for these two key lines:

```
VPC Capability: VPC-VIP-Only [notified]
Source-Interface: loopback1 (primary: 10.0.1.21, secondary: 10.0.1.100)
```

The `[notified]` flag confirms NX-OS has been told about vPC and
flipped its source advertisement to use the VIP (the secondary IP).

If you see `VPC Capability: None`: the secondary IP didn't apply.
Check that loopback1 has both addresses:
```
show running-config interface loopback1
```

## Check 3: EVPN routes advertise the shared VTEP

This is the structural proof of what 6c achieves.

```
show bgp l2vpn evpn route-type 2
```

Look for host1's MAC entry. The originating next-hop should be
`10.0.1.100` (the shared VIP), not `10.0.1.21` (leaf1's loopback)
or `10.0.1.22` (leaf2's loopback):

```
Route Distinguisher: 10.0.0.21:32777    (L2VNI 10010)
BGP routing table entry for [2]:[0]:[0]:[48]:[<host1-mac>]:...
  Path type: local, path is valid, is best path
    10.0.1.100 (metric 0) from 0.0.0.0       <-- shared VTEP!
      Extcommunity: RT:65000:10010 SOO:10.0.1.100:0 ENCAP:8
```

**`SOO:10.0.1.100`** is the Site-of-Origin extended community
saying "this route came from the vPC pair as a whole."

If next-hop shows `10.0.1.21` instead of `10.0.1.100`: NVE didn't
switch to using the secondary. See troubleshooting below.

## Check 4: host1 connectivity restored

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
```

Expected: 100% success, TTL=63.

The same ping that was failing in the broken-6b state now works
because vPC member ports came up after the consistency check passed.

## Check 5: Sessions 1-5 functionality preserved

vPC layered under multi-tenant + route leak should still work:

```bash
# Cross-tenant via route leak (Session 5b)
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: succeeds.

## Check 6: The killer demo — leaf failure with host bond up

This is what production cares about.

In one terminal:

```bash
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

Leave running.

In another terminal:

```bash
docker stop clab-vxlan-evpn-leaf1
```

**Expected**: ping continues with maybe 1-2 dropped packets during
convergence. Traffic shifts entirely to leaf2. The bond detects
eth1 going down (MII status), LACP rebalances flows to eth2.

Verify the bond state:
```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | grep -E "MII Status|Aggregator|Slave Interface"
```

eth1 should show MII Status: down. eth2 should still be up.

**Restore**:
```bash
docker start clab-vxlan-evpn-leaf1
# Wait ~60-90 sec for leaf1 to fully come back
```

After leaf1 returns, the bond's eth1 slave will come back up,
and vPC will re-form. EVPN routes will be readvertised from the
shared 10.0.1.100 VTEP.

## Troubleshooting

### Consistency still failed after applying 6c

OSPF hasn't propagated the new loopback secondary IP yet. Check
on another leaf or spine:
```
show ip ospf database | include 10.0.1.100
```

If absent, OSPF hasn't seen it yet. Wait 30 sec or bounce OSPF.

### EVPN next-hop is still 10.0.1.21, not 10.0.1.100

NVE is using the primary IP for advertisements. Two checks:

```
show nve interface nve1 detail | include "VPC Capability"
```

If `None`: NX-OS didn't recognize the vPC pairing. Confirm both
leaves have IDENTICAL secondary IPs:
```
show running-config interface loopback1
```

Both leaves should show `ip address 10.0.1.100/32 secondary`. If
they differ, fix and re-deploy.

If `VPC-VIP-Only [notified]` is shown but next-hops still show
primary IPs, **clear BGP** to force readvertisement:
```
clear ip bgp 10.0.0.11 soft out
clear ip bgp 10.0.0.12 soft out
```

### vPC 10 went down despite consistency success

vPC delay-restore timer is active. Each vPC member port waits up
to 150 seconds after recovery before bringing the port up. This
is intentional — it prevents traffic black-holing during BGP/IGP
convergence. Wait it out:
```
show vpc | include "Delay-restore"
```

If `Timer is on`, just wait.

## Summary

If Checks 1-6 pass, Session 6c is verified:
- vPC consistency status: success
- NVE in VPC-VIP-Only mode
- EVPN advertises via shared 10.0.1.100 VTEP
- host1 LACP bond fully working through vPC pair
- Leaf failure survival demonstrated

**You now have a production-shape VXLAN-EVPN fabric:**
- Spine-leaf underlay (OSPF)
- BGP-EVPN overlay with spine RRs
- Multi-tenant VRFs with anycast gateways
- Symmetric route leaking
- vPC dual-homing with shared VTEP
- Chassis-level resilience

This is the topology and config shape most modern data center
fabrics use, scaled to 4 nodes for a laptop.
