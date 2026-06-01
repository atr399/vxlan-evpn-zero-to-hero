# Session 5b: Verification — Route Leak Lets Cross-Tenant Traffic Through

## Pre-check: 5a was working before this deploy

Confirm 5a's isolation is real before we break it. From host1:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 2 10.200.10.10
```

If this **succeeds** before you've applied 5b, route leaking is
already active (or VRFs aren't truly separated) — investigate
before continuing.

If it **fails** (expected), proceed to deploy 5b.

## Deploy 5b

```bash
./scripts/switch.sh 05b-route-leak
```

No host reconfiguration needed — host IP setup from 5a is still
valid.

## Check 1: Import lines are present on both leaves

```
ssh admin@clab-vxlan-evpn-leaf1
```

```
show running-config | section "vrf context Tenant-A"
```

Expected:
```
vrf context Tenant-A
  vni 50001
  rd auto
  address-family ipv4 unicast
    route-target both auto
    route-target both auto evpn
    route-target import 65000:50002
    route-target import 65000:50002 evpn
```

The two `route-target import 65000:50002` lines are the leak. They
tell Tenant-A: "import EVPN routes tagged with Tenant-B's L3VNI
RT."

Symmetric leak — Tenant-B's section should also have imports of
65000:50001:

```
show running-config | section "vrf context Tenant-B"
```

Expected:
```
vrf context Tenant-B
  vni 50002
  rd auto
  address-family ipv4 unicast
    route-target both auto
    route-target both auto evpn
    route-target import 65000:50001
    route-target import 65000:50001 evpn
```

## Check 2: Tenant-A's route table now includes Tenant-B routes

```
show ip route vrf Tenant-A
```

Expected: alongside Tenant-A's own subnets (10.100.x.x), you now
see **10.200.x.x** prefixes too. They'll have a `via 10.0.1.X`
next-hop (the remote VTEP) and show as BGP-learned.

```
show ip route vrf Tenant-B
```

Same logic, opposite direction — Tenant-B now has 10.100.x.x
entries.

## Check 3: Confirm the leak in BGP

```
show bgp ipv4 unicast vrf Tenant-A
```

Look for entries with prefixes starting `10.200.` — those are the
imported Tenant-B routes:

```
*>i10.200.10.0/24      10.0.1.22    100      0 ?
*>i10.200.20.0/24      10.0.1.22    100      0 ?
```

The `i` flag means "internal/BGP-learned" and `>` means "best
path." These shouldn't be there in 5a.

## Check 4: The Type-5 entries show import annotations

```
show bgp l2vpn evpn route-type 5 detail | include "Imported"
```

Look for lines like `Imported to: Tenant-A`. These confirm BGP is
explicitly importing the route into the cross-VRF table.

## Check 5: THE moment of truth — cross-tenant ping must SUCCEED

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
```

**Expected: succeeds, TTL = 62.**

Same TTL as Session 4's cross-subnet ping. Why? Because the packet
still crosses two leaves (each leaf doing L3), even though it's
now crossing VRF boundaries. The leak operates at the **control
plane**, not the data plane.

If this fails:
- Check `_push.log` for any cfg push errors
- Verify both `route-target import` directions are present
- Confirm BGP sessions are still up (5b doesn't touch BGP peering
  but always worth checking)

## Check 6: Capture the leaked packet (optional)

```bash
./scripts/capture.sh leaf1 eth1 05b-cross-tenant 'udp port 4789'
```

In another terminal:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 10 10.200.10.10
```

Open the resulting pcap in Wireshark. Look at the VXLAN VNI on
the outer header.

Notable observations:
- **Outgoing direction** (host1 → host2): VNI **50001** (Tenant-A's
  L3VNI — because the packet originates in Tenant-A's plane)
- **Return direction** (host2 → host1): VNI **50002** (Tenant-B's
  L3VNI)

Bidirectional traffic uses both L3VNIs — one per direction. This
is the subtle thing route leaking does that monolithic
single-tenant routing doesn't.

## Check 7: Reverse ping also works

```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 10.100.10.10
```

Symmetric leak means traffic flows both ways.

## What this verifies

If Checks 1-7 pass, Session 5b is complete:
- Route leak is configured symmetrically between Tenant-A and
  Tenant-B
- Each VRF's route table now contains the other's subnets
- Cross-tenant ping succeeds, TTL=62 (still two L3 hops, just
  crossing VRFs)
- Wireshark shows different L3VNIs for forward vs. return traffic

## To go back to isolation

```bash
./scripts/switch.sh 05a-tenant-b
```

This re-pushes 5a's config, which doesn't have the import lines.
However, **NX-OS doesn't auto-remove the import lines** just
because they're absent in a new push. You'd need to explicitly
remove them with `no route-target import ...` commands. For our
teaching purposes, going back to isolation requires a fresh
deploy (`./scripts/deploy.sh 05a-tenant-b`).

This is a real-world gotcha. In production you'd manage VRF
leaks via change-controlled procedures, not by re-pushing configs
expecting them to be subtractive.
