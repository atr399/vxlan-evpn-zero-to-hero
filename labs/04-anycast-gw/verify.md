# Session 4: Verification

## Check 0: Hosts have IPs AND default route via the lab gateway

The most common Session 4 trap. Re-confirm both:

```bash
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host1 ip route
docker exec clab-vxlan-evpn-host2 ip addr show eth1
docker exec clab-vxlan-evpn-host2 ip route
```

What you want to see for host1:
- `inet 10.100.10.10/24` on eth1
- `default via 10.100.10.1 dev eth1` — **not via eth0**

If the default is via eth0, the host will send tenant traffic out the
wrong interface. Re-run with `ip route replace`:

```bash
docker exec clab-vxlan-evpn-host1 sh -c "ip route replace default via 10.100.10.1"
docker exec clab-vxlan-evpn-host2 sh -c "ip route replace default via 10.100.20.1"
```

## Check 1: Distributed gateway MAC is set

On either leaf:

```
show running-config | include "anycast-gateway-mac"
```

Expected:

```
fabric forwarding anycast-gateway-mac 0000.2222.3333
```

This MAC must match on both leaves.

## Check 2: SVIs are up and in the right VRF

```
show ip interface brief vrf Tenant-A
```

Expected (on either leaf):

```
Vlan10    10.100.10.1     protocol-up/link-up/admin-up
Vlan20    10.100.20.1     protocol-up/link-up/admin-up
Vlan99    forward-enabled protocol-up/link-up/admin-up
```

Vlan99 shows `forward-enabled` because it's the L3VNI carrier with
`ip forward` (no IP needed).

## Check 3: SVIs are in anycast mode

```
show running-config interface Vlan10 | include "fabric forwarding"
```

Should show `fabric forwarding mode anycast-gateway`.

## Check 4: L3VNI status

```
show nve vni
```

Now shows **three** VNIs — two L2 and one L3:

```
Interface VNI    Multicast-group State Mode Type [BD/VRF]
nve1      10010  UnicastBGP      Up    CP   L2 [10]
nve1      10020  UnicastBGP      Up    CP   L2 [20]
nve1      50001  n/a             Up    CP   L3 [Tenant-A]
```

The L3VNI shows `L3 [Tenant-A]` — bound to the VRF, not a VLAN.

## Check 5: BGP EVPN shows Type-5 routes

This is the check that catches the redistribute bug. After hosts have
been pinged at least once:

```
show bgp l2vpn evpn summary
```

Look at the route-type breakdown:

```
Neighbor      T    AS Type-1 Type-2 Type-3 Type-4 Type-5 ...
10.0.0.11     I 65000 0      3      2      0      2      ...
10.0.0.12     I 65000 0      3      2      0      2      ...
```

**Type-5 must be non-zero.** If it's 0:
- Confirm `redistribute direct route-map ALL_ROUTES` is present:
  ```
  show running-config | section "router bgp"
  ```
- Confirm the route-map exists:
  ```
  show route-map ALL_ROUTES
  ```

```
show bgp l2vpn evpn route-type 5
```

Should show Type-5 routes for `10.100.10.0/24` and `10.100.20.0/24`,
originated locally (Path type: local) AND received from the remote
leaf via the spine RRs (Path type: internal).

## Check 6: VRF route table shows fabric-learned prefixes

```
show ip route vrf Tenant-A
```

Look for entries with `via 10.0.1.X` (remote VTEP IP) — those are the
EVPN-learned routes. You'll also see `direct` routes for your own
SVIs and `hmm` (host mobility manager) entries when hosts have been
seen.

## Check 7: BGP IPv4 table for the VRF (the redistribute check)

```
show bgp ipv4 unicast vrf Tenant-A
```

You should see entries marked with **`r`** (redistributed):

```
*>r10.100.10.0/24    0.0.0.0    0    100    32768 ?
*>r10.100.20.0/24    0.0.0.0    0    100    32768 ?
```

The `r` flag confirms `redistribute direct` is working. Without it,
Type-5 routes won't be generated.

## Check 8: Host can ping its own gateway (anycast works)

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1
```

Should succeed with sub-millisecond to ~1ms latency (local leaf
answering). Verify the anycast MAC:

```bash
docker exec clab-vxlan-evpn-host1 arp -n
```

You should see `10.100.10.1` with HWaddress `00:00:22:22:33:33`.

## Check 9: Cross-subnet ping (the moment of truth)

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

Should succeed. Look at the TTL in the reply — it should be **62**
(started at 64, decremented twice by the two leaves performing L3).
That TTL decrement is your visual proof of symmetric IRB.

The first packet may be lost during ARP resolution. Subsequent
packets should have consistent low-millisecond latency.

## Check 10: Packet capture — confirm L3VNI in use

In one terminal:

```bash
./scripts/capture.sh leaf1 eth1 04-cross-subnet-vni50001 'udp port 4789'
```

In another:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

Open the saved pcap in Wireshark. You should see:

- Outer IPs: 10.0.1.21 <-> 10.0.1.22
- **VXLAN VNI: 50001** (L3VNI — not 10010 or 10020)
- Inner Ethernet MACs: anycast gateway MAC (`00:00:22:22:33:33`)
- Inner IPs: host1's IP (10.100.10.10) and host2's IP (10.100.20.10)

Save this pcap. It's permanent evidence the fabric uses symmetric IRB.

## Summary

- Three VNIs operational (10010, 10020, 50001)
- SVIs in anycast mode, gateway MAC matches across leaves
- `redistribute direct route-map ALL_ROUTES` configured (the critical
  fix discovered during initial testing)
- BGP EVPN Type-5 routes flowing both directions
- Hosts have default routes via lab gateway (not via clab management)
- host1 (VLAN 10) pings host2 (VLAN 20) successfully, TTL = 62
- Wireshark confirms transit happens on VNI 50001

If all 10 checks pass, Session 4 is complete.
