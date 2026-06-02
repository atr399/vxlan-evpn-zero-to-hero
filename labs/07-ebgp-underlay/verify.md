# Session 7: Verification — eBGP Underlay + eBGP-EVPN Overlay

## Step 1: Apply Session 7

```bash
./scripts/switch.sh 07-ebgp-underlay
```

Expected: ~10-15 sec, "Config OK on leaf1 (found: router bgp 65011)"

The push starts with `no router ospf UNDERLAY` and `no router bgp 65000`
— deletes the old protocols cleanly. Then adds the new eBGP design.

**Expect a ~30-60 sec window where the lab is partially converged.**
OSPF was removed, eBGP is forming, EVPN sessions are reconnecting.
Cross-tenant ping may briefly fail. Wait it out.

## Check 1: Confirm OSPF is gone

```
ssh admin@clab-vxlan-evpn-leaf1
show ip ospf neighbors
```

Expected: `OSPF Routing Protocol not enabled` or similar. **No
neighbors.**

```
show running-config | include "router ospf"
```

Expected: no output. The OSPF process is deleted.

## Check 2: eBGP underlay sessions Established

```
show bgp ipv4 unicast summary
```

Expected on leaf1 (AS 65011):

```
BGP summary information for VRF default, address family IPv4 Unicast
BGP router identifier 10.0.0.21, local AS number 65011

Neighbor      V    AS    MsgRcvd    MsgSent  TblVer  InQ OutQ Up/Down  State/PfxRcd
10.10.1.0     4 65001         X          X        Y    0    0 00:00:30 N
10.10.3.0     4 65002         X          X        Y    0    0 00:00:30 N
```

Both peers should be in Established state (the number in PfxRcd
column means how many prefixes received from that neighbor).

If state is `Idle` or `Active`: the session isn't up. Check:
- physical link state
- IP addressing on the link
- the spine has matching neighbor config

## Check 3: Loopback reachability through eBGP

```
show ip route 10.0.0.22
```

Expected: route to leaf2's loopback via the spines, learned by BGP:

```
10.0.0.22/32, ubest/mbest: 2/0
    *via 10.10.1.0, [20/0], 00:00:30, bgp-65011, external, tag 65001
    *via 10.10.3.0, [20/0], 00:00:30, bgp-65011, external, tag 65002
```

Two paths (ECMP via both spines), both `bgp-65011, external`.

```
show ip route 10.0.1.100
```

Expected: also reachable, the shared VTEP IP. This is critical — if
loopback1 isn't reachable, VXLAN tunneling breaks.

## Check 4: eBGP-EVPN sessions Established

```
show bgp l2vpn evpn summary
```

Expected on leaf1:

```
BGP summary information for VRF default, address family L2VPN EVPN
BGP router identifier 10.0.0.21, local AS number 65011

Neighbor      V    AS    MsgRcvd    MsgSent  TblVer  InQ OutQ Up/Down  State/PfxRcd
10.10.1.0     4 65001        X          X        Y    0    0 00:01:00 N
10.10.3.0     4 65002        X          X        Y    0    0 00:01:00 N
```

Same neighbors as the IPv4 unicast view but for the EVPN AF.
Both Established.

## Check 5: EVPN Type-2 routes received with REWRITTEN RTs

This is the most important check — it proves `rewrite-evpn-rt-asn`
on the spines is doing its job.

```
show bgp l2vpn evpn route-type 2
```

Look for a route originating from leaf2 (host2's MAC). The
extended-community RT field should show `RT:65000:10030` — the
**globally consistent** RT we configured, NOT `65012:10030`
(which would mean spine didn't rewrite).

If you see `65012:` or `65000:` mixed, the rewrite didn't happen.
Confirm spine config has `rewrite-evpn-rt-asn` under each leaf
neighbor.

## Check 6: VXLAN data plane still works

The whole stack should be operational again.

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: succeeds, TTL=62 or 63 (depending on path).

If this fails: most likely cause is the RT rewriting isn't happening.
Verify on the spine:
```
ssh admin@clab-vxlan-evpn-spine1
show running-config | include "rewrite-evpn-rt-asn"
```

Should show 2 occurrences (one per leaf neighbor).

## Check 7: vPC still works

vPC is protocol-independent of the underlay routing. Should still
be healthy.

```
show vpc
```

Expected:
- `Peer status: peer adjacency formed ok`
- `vPC keep-alive status: peer is alive`
- `Configuration consistency status: success`
- `vPC 10: Po10 up`

## Check 8: ECMP active

```
show ip route 10.0.0.22
```

Confirm 2 paths (one via each spine). If only 1: check `maximum-paths
2` is in BGP config.

## Check 9: VRF isolation + leak still working

```
show ip route vrf Tenant-A | include "10.200"
```

Should show 10.200.x.x prefixes (leaked from Tenant-B).

```
show ip route vrf Tenant-B | include "10.100"
```

Should show 10.100.x.x prefixes (leaked from Tenant-A).

## Summary

If Checks 1-9 pass, Session 7 is verified:
- OSPF entirely removed
- eBGP underlay sessions Established with per-device ASNs
- eBGP-EVPN overlay also functional (different AS per neighbor)
- Spine RT rewriting (`rewrite-evpn-rt-asn`) making routes work
  across ASN boundary
- vPC + VXLAN data plane preserved
- All Sessions 1-6 functionality intact

This is the **hyperscale-style fabric**. What Microsoft, Meta,
Cloudflare actually deploy in their data centers.

## Troubleshooting

### "Configuration consistency: failed" — Type 1 mismatch about ASN

vPC's consistency check may flag the new local-AS on the leaves.
Look at:
```
show vpc consistency-parameters global
```

If `local-as` mismatch appears, the two leaves need to be in the
same ASN for vPC. Confirm leaf1 = 65011 and leaf2 = 65012 — wait,
those are DIFFERENT.

**This is intentional** in this lab but it's a real-world tension:
vPC pair typically uses same ASN. We have separate ASNs to teach
the RFC 7938 pattern cleanly, even though it means vPC behaves
sub-optimally.

In real production with vPC + eBGP per-device-ASN, operators
usually keep BOTH vPC leaves in the same ASN. We chose
different ASNs here for teaching clarity at the cost of some
realism.

If vPC consistency becomes a real problem in your environment,
the fix is to use the same ASN for both leaves (e.g., both at
65011), with `allowas-in` configured to handle the loop scenario.
