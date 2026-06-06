# Session 9: Verification - L3Out (eBGP Dual-Attached, cEOS Extrouter)

## Pre-check: All 10 containers running

```bash
docker ps | grep clab-vxlan-evpn
```

Expected: 10 containers, all "Up", with the four NX-OS leaves/spines healthy.

The extrouter is `arista_ceos` kind, boots in ~30-60 sec.

## Step 1: Apply Session 9

```bash
./scripts/switch.sh 09-l3out
```

Expected: ~10 sec push. Marker "neighbor 192.0.2.0" found.

## Step 2: Configure host_internet

```bash
docker exec clab-vxlan-evpn-host_internet sh -c '
  ip addr flush dev eth1
  ip addr add 203.0.113.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 203.0.113.1
'
```

extrouter loaded its startup-config at deploy time. No FRR install needed.
No manual interface config needed. cEOS handles it.

## Step 3: Verify extrouter BGP state

```bash
docker exec clab-vxlan-evpn-extrouter Cli -c 'show ip bgp summary'
```

Expected:
```
Neighbor   V  AS    MsgRcvd  MsgSent  ...  Up/Down  State/PfxRcd
192.0.2.1  4  65000  ...                    Estab     3
192.0.2.3  4  65000  ...                    Estab     3
```

Both leaves established, each advertising the three Tenant-A subnets
(10.100.10.0/24, 10.100.20.0/24, 10.100.50.0/24).

```bash
docker exec clab-vxlan-evpn-extrouter Cli -c 'show ip route'
```

Expected: routes for 10.100.x.x/24 with two next-hops (ECMP from both
leaves), plus 203.0.113.0/24 connected.

## Step 4: Verify leaf1's BGP

```
ssh admin@clab-vxlan-evpn-leaf1
show bgp vrf Tenant-A ipv4 unicast summary
```

Expected:
```
Neighbor   V    AS     MsgRcvd MsgSent  Up/Down   PfxRcd
192.0.2.0  4    65100  ...              Estab     1
```

1 prefix received = 203.0.113.0/24 from extrouter.

```
show ip route 203.0.113.0/24 vrf Tenant-A
```

Expected:
```
203.0.113.0/24, ubest/mbest: 1/0
  *via 192.0.2.0, [20/0], 00:00:30, bgp-65000, external, tag 65100
```

## Step 5: Verify EVPN Type-5 propagation

```
show bgp l2vpn evpn route-type 5 | include 203.0.113
```

Expected: 203.0.113.0/24 entry visible as Type-5 EVPN route.

## Step 6: Verify leaf2's BGP

```
ssh admin@clab-vxlan-evpn-leaf2
show bgp vrf Tenant-A ipv4 unicast summary
```

Expected: leaf2 also has eBGP session up (Estab) with 192.0.2.2 (its
own connection to extrouter), and 1 prefix received.

```
show ip route 203.0.113.0/24 vrf Tenant-A
```

Expected: route via 192.0.2.2 (leaf2's own direct eBGP path), [20/0]
external.

**This is the key win of dual-attached**: leaf2 doesn't need to go
through leaf1 via VXLAN. It has its own direct L3Out path.

## Step 7: End-to-end tests

```bash
# Test 1: host1 (Tenant-A on leaf1) to the internet
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
```

Expected: succeeds. Path: host1 -> leaf1 -> extrouter -> host_internet.

```bash
# Test 2: host2 (Tenant-B on leaf2) to the internet via leak
docker exec clab-vxlan-evpn-host2 ping -c 3 203.0.113.10
```

Expected: succeeds. Path: host2 -> leaf2 (Tenant-B) -> leak -> leaf2
Tenant-A -> extrouter -> host_internet. This is the case that used to
fail with single-attached; now leaf2 has its own L3Out path.

```bash
# Test 3: external to fabric host1
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.10.10
```

Expected: succeeds. extrouter has 10.100.10.0/24 via both leaves (ECMP).

```bash
# Test 4: external to fabric host2 (cross-tenant via leak)
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.200.10.10
```

Expected: succeeds (path goes via either leaf1 or leaf2, route leak does
the rest).

## Step 8: Verify ECMP works

```bash
docker exec clab-vxlan-evpn-extrouter Cli -c 'show ip route 10.100.10.0/24'
```

Expected: TWO next-hops (192.0.2.1 and 192.0.2.3), proving ECMP load-
balancing from extrouter back into the fabric.

## Step 9: Failover test

Shut leaf1's L3Out interface:

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/7
shutdown
end
exit
```

Then test:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
docker exec clab-vxlan-evpn-host2 ping -c 3 203.0.113.10
```

Expected: BOTH still work. host1's traffic now travels via VXLAN to leaf2,
then out leaf2's eBGP session to extrouter. **This is the failure-mode
benefit of dual-attached L3Out.**

Restore:
```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/7
no shutdown
end
exit
```

## Summary

Session 9 dual-attached L3Out verified:
- Two eBGP sessions, each leaf to extrouter via its own /31
- ECMP load-balancing both directions
- No shared-VIP confusion (each leaf advertises with its own PIP)
- Failover works automatically via EVPN/BGP

This is the production-standard pattern. The cross-tenant case (host2 to
internet) now works cleanly because leaf2 has its own L3Out path.

## Troubleshooting

### eBGP sessions stuck in Idle/Active

Check interface state:
```
ssh admin@clab-vxlan-evpn-leaf1
show interface Ethernet1/7
ping 192.0.2.0 vrf Tenant-A
```

Should ping the extrouter. If not, check that extrouter's interfaces
came up with the startup-config.

```bash
docker exec clab-vxlan-evpn-extrouter Cli -c 'show interfaces description'
```

### No prefixes received from extrouter

```bash
docker exec clab-vxlan-evpn-extrouter Cli -c 'show ip bgp neighbors 192.0.2.1 advertised-routes'
```

Should show 203.0.113.0/24. If empty: check that `network 203.0.113.0/24`
plus the Null0 route are present in extrouter's running-config.

### EVPN Type-5 not propagating

```
show bgp l2vpn evpn route-type 5 | include 203.0.113
```

If empty on leaf1 even though route is in Tenant-A RIB: verify the
`advertise l2vpn evpn` line is present under `vrf Tenant-A` in BGP.

### host_internet has no eth1

The clab veth for the link to extrouter didn't materialize. Verify:
```bash
docker exec clab-vxlan-evpn-host_internet ip link show
```

If only lo and eth0, the deploy didn't wire the link. Try
`containerlab destroy` and redeploy.
