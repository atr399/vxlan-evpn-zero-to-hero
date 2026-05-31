# Session 4: Break It On Purpose

Four exercises that reveal anycast gateway and symmetric IRB by
breaking them. Each includes a capture step so you can see the failure
mode in Wireshark, not just the show-command output.

---

## Exercise 1: Mismatched anycast gateway MAC

**Scenario**: Operator typo — leaf1 has `0000.2222.3333` but leaf2 has
`0000.4444.5555`. What happens?

**Before**: Cross-subnet ping works.

**Action**: On leaf2 only, change the anycast MAC.

```
leaf2# configure terminal
leaf2(config)# fabric forwarding anycast-gateway-mac 0000.4444.5555
leaf2(config)# end
```

**Capture**:

```bash
./scripts/capture.sh leaf1 eth1 break1-mismatched-anycast-mac 'arp or udp port 4789'
```

In another terminal:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

**Observe**: Ping likely still works at first (host1's ARP cache is
valid for leaf1's MAC). Now move host1 mentally to leaf2's behavior —
or in a real fabric, when a host on leaf2 with a stale cache from
leaf1 sends to the gateway, the MAC won't match what's currently
expected.

In Wireshark, search for ARP traffic. You may see ARP probes or
confusion in the EVPN MAC-Mobility (Type-2) routes. With one anycast
MAC config'd wrong, MAC flap detection in EVPN can trigger.

**Teaching point**: Anycast gateway MACs **must** match across all
leaves participating in the same VRF/VLAN. A mismatch creates subtle
mobility and reconvergence bugs.

**Restore**:

```
leaf2# configure terminal
leaf2(config)# fabric forwarding anycast-gateway-mac 0000.2222.3333
leaf2(config)# end
```

---

## Exercise 2: Remove `advertise-pip`

**Scenario**: An operator removes `advertise-pip` from BGP EVPN config.
What changes in EVPN Type-5 advertisements?

**Action** on leaf1:

```
leaf1# configure terminal
leaf1(config)# router bgp 65000
leaf1(config-router)# address-family l2vpn evpn
leaf1(config-router-af)# no advertise-pip
leaf1(config-router-af)# end
```

**Observe**:

```
leaf2# show bgp l2vpn evpn route-type 5 detail
```

Look at routes received from leaf1. The next-hop field may now show
the anycast gateway IP instead of leaf1's PIP (loopback1). This is
the wrong behavior — anycast IPs are not unique, so they don't make
sense as a BGP next-hop.

In the capture, follow Type-5 routes from leaf1 and verify the
next-hop. Without `advertise-pip`, traffic might end up going to a
random leaf instead of the specific one originating the route.

**Teaching point**: `advertise-pip` ensures Type-5 routes correctly
identify which physical leaf originated them, even when the SVI itself
is anycast across many leaves.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# router bgp 65000
leaf1(config-router)# address-family l2vpn evpn
leaf1(config-router-af)# advertise-pip
leaf1(config-router-af)# end
```

---

## Exercise 3: Remove the L3VNI association

**Scenario**: An operator removes `member vni 50001 associate-vrf` from
nve1. Symmetric IRB cannot work without it.

**Action** on leaf1:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# no member vni 50001 associate-vrf
leaf1(config-if-nve)# end
```

**Capture**:

```bash
./scripts/capture.sh leaf1 eth1 break3-no-l3vni 'udp port 4789'
```

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

**Observe**:
- Ping fails or behaves erratically
- The capture shows... what exactly? Inspect in Wireshark. You may
  see Type-2 EVPN routes for host MACs but no L3VNI traffic flowing.
  The fabric doesn't know how to encapsulate routed traffic.

```
leaf1# show nve vni
```

VNI 50001 is gone from the list.

**Teaching point**: The L3VNI membership on the NVE is what gives the
data plane the encap path for routed traffic. Without it, the fabric
knows the routes (control plane) but can't move the packets (data
plane).

**Restore**:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# member vni 50001 associate-vrf
leaf1(config-if-nve)# end
```

---

## Exercise 4: Capture and compare L2 vs L3 VXLAN

**Scenario**: Pure educational. Capture the difference between an
intra-subnet ping (L2VNI) and a cross-subnet ping (L3VNI).

**Setup**: Add a second host to VLAN 10 to allow intra-subnet ping.
You'll do this temporarily for the exercise:

```bash
# Get host2 into VLAN 10 for this test by moving the access vlan on leaf2
ssh admin@clab-vxlan-evpn-leaf2
```

```
leaf2# configure terminal
leaf2(config)# interface Eth1/3
leaf2(config-if)# switchport access vlan 10
leaf2(config-if)# end
leaf2# exit
```

Reset host2's IP to be in 10.100.10.0/24:

```bash
docker exec clab-vxlan-evpn-host2 sh -c "ip addr flush dev eth1 && ip addr add 10.100.10.11/24 dev eth1 && ip route add default via 10.100.10.1"
```

**Capture intra-subnet** (host1 to host2, same subnet):

```bash
./scripts/capture.sh leaf1 eth1 exercise4-intra-subnet-l2vni 'udp port 4789'
```

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.10.11
```

In Wireshark: should be VNI 10010 (L2VNI).

**Revert host2 back to VLAN 20**:

```
leaf2# configure terminal
leaf2(config)# interface Eth1/3
leaf2(config-if)# switchport access vlan 20
leaf2(config-if)# end
```

```bash
docker exec clab-vxlan-evpn-host2 sh -c "ip addr flush dev eth1 && ip addr add 10.100.20.10/24 dev eth1 && ip route add default via 10.100.20.1"
```

**Capture cross-subnet** (host1 in VLAN 10 to host2 in VLAN 20):

```bash
./scripts/capture.sh leaf1 eth1 exercise4-cross-subnet-l3vni 'udp port 4789'
```

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

In Wireshark: should be VNI 50001 (L3VNI).

**Compare the two captures side by side**. The visible differences:

| Aspect | Intra-subnet (VNI 10010) | Cross-subnet (VNI 50001) |
|--------|--------------------------|--------------------------|
| Outer UDP dst port | 4789 | 4789 |
| VXLAN VNI | 10010 | 50001 |
| Inner src MAC | host1's MAC | leaf1's anycast MAC |
| Inner dst MAC | host2's MAC | leaf2's anycast MAC |
| Inner src IP | 10.100.10.10 | 10.100.10.10 (unchanged) |
| Inner dst IP | 10.100.10.11 | 10.100.20.10 |

The inner MAC rewriting is the giveaway: in the L3 case, the inner
Ethernet frame's MACs are the anycast gateway, because routing
happened at leaf1. The original host MAC never leaves leaf1.

This is **symmetric IRB**. Both leaves see the same VNI (50001) for
inter-subnet traffic. The L2VNI doesn't transit.

**Teaching point**: This visual comparison is the clearest possible
demonstration of why we call it "symmetric IRB" — both directions
use the same L3VNI, and both ends do the routing.

---

## After these exercises

If you can answer:
- Why anycast MAC must match across all leaves
- What `advertise-pip` does and why it matters
- The exact role of L3VNI association on nve1
- The visible difference between L2VNI and L3VNI traffic in Wireshark

…you understand the routed VXLAN-EVPN fabric.

Reset to clean state:

```bash
./scripts/reset.sh 04-anycast-gw
```

Don't forget to re-run the manual host IP config after redeploy.
