# Session 5a: Verification — Tenant-B Exists, Isolation Holds

## Pre-check: Hosts have IPs in the right tenants

```bash
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host1 ip route
docker exec clab-vxlan-evpn-host2 ip addr show eth1
docker exec clab-vxlan-evpn-host2 ip route
```

Expected:
- host1: `inet 10.100.10.10/24` on eth1, `default via 10.100.10.1`
- host2: `inet 10.200.10.10/24` on eth1, `default via 10.200.10.1`

If host2 still has 10.100.20.10 (Session 4's address), re-run the
host setup from the doc — host2 needs to move into Tenant-B's subnet.

## Check 1: Both VRFs exist on each leaf

```
ssh admin@clab-vxlan-evpn-leaf1
```

```
show vrf
```

Expected:
```
VRF-Name                           VRF-ID State    Reason
Tenant-A                                3 Up       --
Tenant-B                                4 Up       --
default                                 1 Up       --
management                              2 Up       --
```

If Tenant-B is missing or in a Down state, the cfg push didn't
apply cleanly. Check `scripts/_push.log` for errors.

## Check 2: Both L3VNIs are operational

```
show nve vni
```

Expected to include lines for both L3VNIs:
```
nve1   50001  n/a   Up   CP   L3 [Tenant-A]
nve1   50002  n/a   Up   CP   L3 [Tenant-B]
```

Plus all four L2VNIs (10010, 10020, 10030, 10040) in their VLANs.

## Check 3: Anycast gateways are up in Tenant-B

```
show ip interface brief vrf Tenant-B
```

Expected:
```
Vlan30    10.200.10.1     protocol-up/link-up/admin-up
Vlan40    10.200.20.1     protocol-up/link-up/admin-up
Vlan98    forward-enabled protocol-up/link-up/admin-up
```

`Vlan98` is the L3VNI 50002 carrier — same role as Vlan99 for
Tenant-A.

## Check 4: BGP EVPN has Type-5 routes for both tenants

```
show bgp l2vpn evpn summary
```

After hosts ping their gateways, you should see Type-5 routes
flowing. Look at the per-neighbor totals.

```
show bgp l2vpn evpn route-type 5
```

Expected: prefixes for **both** Tenant-A subnets (10.100.x.x) AND
Tenant-B subnets (10.200.x.x), each tagged with their own RTs:

- 10.100.10.0/24, 10.100.20.0/24 → RT `65000:50001`
- 10.200.10.0/24, 10.200.20.0/24 → RT `65000:50002`

The RT difference is the **structural mechanism** that keeps the
VRFs apart.

## Check 5: VRF route tables show only their own routes

This is the **structural proof of isolation**.

```
show ip route vrf Tenant-A
```

Expected: routes for 10.100.10.0/24 and 10.100.20.0/24 only.
**No 10.200.x.x prefixes.**

```
show ip route vrf Tenant-B
```

Expected: routes for 10.200.10.0/24 and 10.200.20.0/24 only.
**No 10.100.x.x prefixes.**

Each VRF literally doesn't know the other exists in its routing
plane.

## Check 6: Each host can ping its own gateway

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1
docker exec clab-vxlan-evpn-host2 ping -c 3 10.200.10.1
```

Both should succeed at sub-millisecond to ~1ms (local leaf).

## Check 7: THE isolation proof — cross-tenant ping must FAIL

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

**Expected: 100% packet loss.**

This is the proof that VRFs are real. host1 (in Tenant-A) has no
route to 10.200.10.10 (in Tenant-B). The ping should:
- Time out (most common — the packet leaves host1 but never gets a
  reply, because leaf1 has no route in Tenant-A)
- Or fail with "Destination Host Unreachable" if leaf1 sends an
  ICMP unreachable

If this ping succeeds, isolation is broken. Likely cause: route
leak is configured when it shouldn't be (you accidentally deployed
5b instead of 5a), or VRF assignment on an SVI is wrong.

## Check 8: Confirm the failed ping in NX-OS

After the failed ping above, on leaf1:

```
show ip route vrf Tenant-A 10.200.10.10
```

Expected:
```
Route not found
```

This is the structural proof of why the ping failed.

For comparison, run the same lookup in Tenant-B context:

```
show ip route vrf Tenant-B 10.200.10.10
```

This DOES find a route — to a directly connected interface (host2
is in Vlan30, attached). But because the lookup happens in
Tenant-A's context (since host1's traffic enters Tenant-A's SVI
first), Tenant-B's route table is irrelevant.

## Summary

If Checks 1-8 pass, Session 5a is verified:
- Tenant-B exists alongside Tenant-A
- Anycast gateways work in both VRFs
- BGP EVPN distributes Type-5 routes per VRF (correct RTs)
- Hosts can talk within their own VRF
- **Tenants are isolated** — proven by failed cross-tenant ping

This is the **before** state for Session 5b. Don't fix the isolation
— in 5b we'll deliberately break it via route leaking.
