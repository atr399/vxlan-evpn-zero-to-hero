# Session 4: Verification

## Check 0: Hosts in their respective VLANs and subnets

```bash
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host2 ip addr show eth1
docker exec clab-vxlan-evpn-host1 ip route
docker exec clab-vxlan-evpn-host2 ip route
```

Expected:
- host1: `10.100.10.10/24`, default route via `10.100.10.1`
- host2: `10.100.20.10/24`, default route via `10.100.20.1`

## Check 1: Distributed gateway MAC is set

On either leaf:

```
show fabric forwarding
```

You should see:

```
Anycast-Gateway-MAC : 0000.2222.3333
```

This MAC is used by every anycast gateway SVI on this leaf. Both
leaves must agree.

## Check 2: SVIs are up and in the right VRF

```
show ip interface brief vrf Tenant-A
```

Expected (on either leaf):

```
Vlan10    10.100.10.1     protocol-up/link-up/admin-up
Vlan20    10.100.20.1     protocol-up/link-up/admin-up
Vlan99    --              protocol-up/link-up/admin-up
```

Vlan99 has no IP because it's the L3VNI carrier — it just exists as a
plumbing object linking VNI 50001 to the VRF.

```
show vrf Tenant-A interface
```

Lists every interface that's a member of Tenant-A. You should see
Vlan10, Vlan20, Vlan99.

## Check 3: SVIs are in anycast mode

```
show fabric forwarding ip local-host-db vrf Tenant-A
```

Or simpler — check the running-config for `fabric forwarding mode`:

```
show running-config interface Vlan10 | include "fabric forwarding"
```

Should show `fabric forwarding mode anycast-gateway`.

## Check 4: L3VNI status

```
show nve vni
```

Now shows **three** VNIs:

```
Interface VNI    Multicast-group State Mode Type [BD/VRF]   Flags
nve1      10010  UnicastBGP      Up    CP   L2 [10]
nve1      10020  UnicastBGP      Up    CP   L2 [20]
nve1      50001  UnicastBGP      Up    CP   L3 [Tenant-A]
```

The L3VNI shows `L3 [Tenant-A]` in the Type column — it's bound to
the VRF, not a VLAN.

## Check 5: BGP EVPN now shows Type-5 routes

After ping (next step) triggers route exchange:

```
show bgp l2vpn evpn route-type 5
```

Expected: Type-5 routes for `10.100.10.0/24` and `10.100.20.0/24`,
both originated from both leaves (since both leaves have both SVIs).
Format:

```
Route Distinguisher: 10.0.0.21:3       (L3VNI 50001)
*>l[5]:[0]:[0]:[24]:[10.100.10.0]/224
```

Type-5 = IP Prefix route. The 24 is the prefix length. These routes
let inter-subnet routing work across the fabric.

## Check 6: VRF route table shows fabric-learned prefixes

```
show ip route vrf Tenant-A
```

You should see:
- Connected: `10.100.10.0/24` and `10.100.20.0/24` (your local SVIs)
- BGP EVPN: prefixes from the remote leaf, with next-hop = remote
  VTEP

This is the "fabric as a router" view.

## Check 7: Host can ping its own gateway (anycast works)

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1
```

Should succeed with sub-millisecond latency (it's the local leaf
answering). The reply comes from the anycast MAC `0000.2222.3333`.

Verify the MAC from the host's perspective:

```bash
docker exec clab-vxlan-evpn-host1 arp -n
```

You should see `10.100.10.1` with HWaddress `00:00:22:22:33:33`.

## Check 8: Cross-subnet ping (the moment of truth)

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

Should succeed. This is host1 in VLAN 10/subnet 10 talking to host2 in
VLAN 20/subnet 20 — across two leaves.

## Check 9: Packet capture — confirm L3VNI in use

In one terminal, start the capture:

```bash
./scripts/capture.sh leaf1 eth1 04-cross-subnet-vni50001 'udp port 4789'
```

In another terminal, ping again:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

The capture stops automatically. Open the pcap in Wireshark on your
PC. You should see:

- Outer IPs: 10.0.1.21 (leaf1) <-> 10.0.1.22 (leaf2)
- VXLAN VNI: **50001** (the L3VNI, NOT 10010 or 10020)
- Inner: routed traffic with the **anycast MAC** as src/dst on the
  inner Ethernet header

This is the visual proof of **symmetric IRB**: routing happens on the
local leaf into the L3VNI, and the L3VNI carries the traffic across
the fabric. The destination VLAN's L2VNI (10020) is **not** involved
in the cross-leaf transit.

Save this pcap. It's permanent evidence the fabric works correctly.

## Summary

- All three VNIs (10010, 10020, 50001) operational
- SVIs in anycast mode, all leaves share the same gateway MAC
- BGP EVPN Type-5 routes flowing for IP prefixes
- host1 (VLAN 10) can ping host2 (VLAN 20) across the fabric
- Wireshark proves the inter-subnet traffic crosses the fabric via
  the L3VNI, not the L2VNIs

If all checks pass, you have a fully functional VXLAN-EVPN fabric
with symmetric IRB, the foundation of modern DC networks.
