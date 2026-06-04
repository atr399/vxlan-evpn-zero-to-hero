# Session 8: Break-It Exercises

## Exercise 1: Shut Eth1/6 — host3 becomes unreachable

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/6
shutdown
end
```

**Hypothesis**: host3 loses connectivity to the fabric. host3's
MAC ages out of leaf1's MAC table. Any traffic destined for host3
gets dropped.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10
```

Expected: fails after a few seconds (MAC ages out, no path).

```
show mac address-table vlan 50
```

Should show host3's MAC removed.

**Restore**:
```
configure terminal
interface Ethernet1/6
no shutdown
end
```

Wait ~10 sec for MAC re-learning. Ping should resume.

**Lesson**: L2Out is single-attached in this lab. The external
switch + host3 depend entirely on Eth1/6. In real production,
operators would dual-home the external switch via vPC for
resilience.

## Exercise 2: Remove VLAN 50 from peer-link allowed list

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface port-channel100
switchport trunk allowed vlan remove 50
end
```

**Hypothesis**: leaf2 can no longer see VLAN 50 broadcasts from
the external switch (via peer-link). leaf2's Vlan50 SVI still
exists, anycast gateway still works, but L2 traffic from host3
doesn't bridge to leaf2 over the peer-link.

For traffic from host2 (on leaf2) to host3:
- host2 → leaf2 (Tenant-B → Tenant-A via leak)
- leaf2 needs to reach host3
- EVPN Type-2 says VTEP is 10.0.1.100 (shared VIP)
- Traffic uses VXLAN to leaf1 (which has the local connection)
- This path STILL WORKS even without VLAN 50 on peer-link!

**Verify**:
```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 10.100.50.10
```

Expected: still succeeds, but the path is now strictly via VXLAN
overlay, not via peer-link bridge.

**Restore**:
```
configure terminal
interface port-channel100
switchport trunk allowed vlan add 50
end
```

**Lesson**: VXLAN provides resilience even when traditional L2
bridging breaks. The peer-link is for vPC sync; the actual data
plane uses EVPN-discovered VXLAN tunnels.

## Exercise 3: Misconfigure external bridge — VLAN tag mismatch

The external switch is a Linux bridge with VLAN filtering. What
happens if we configure the wrong VLAN tag?

```bash
docker exec clab-vxlan-evpn-external sh -c '
  bridge vlan del vid 50 dev eth1
  bridge vlan add vid 60 dev eth1 tagged
'
```

This makes the external switch send/receive VLAN 60 frames on
eth1 instead of VLAN 50. leaf1 still expects VLAN 50.

**Hypothesis**: host3 can no longer reach the fabric. Frames from
host3 arrive at leaf1 tagged as VLAN 60, which has no SVI, so
they're dropped.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host3 ping -c 3 10.100.50.1
```

Expected: 100% loss.

**Restore**:
```bash
docker exec clab-vxlan-evpn-external sh -c '
  bridge vlan del vid 60 dev eth1
  bridge vlan add vid 50 dev eth1 tagged
'
```

**Lesson**: L2Out depends on consistent VLAN tagging across the
fabric-to-external boundary. In real deployments, this is a
common misconfig — operations teams document VLAN IDs on
cross-team boundaries explicitly.

## Exercise 4: External switch failure simulation

Stop the external switch container:

```bash
docker stop clab-vxlan-evpn-external
```

**Hypothesis**: host3 becomes unreachable. The fabric can't bridge
through the dead external switch.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10
```

Expected: 100% loss.

**Restore**:
```bash
docker start clab-vxlan-evpn-external
# Wait ~5 sec for the bridge to come back
sleep 5
docker exec clab-vxlan-evpn-external sh -c '
  ip link add br0 type bridge vlan_filtering 1 2>/dev/null || true
  ip link set eth1 master br0
  ip link set eth2 master br0
  bridge vlan add vid 50 dev eth1 tagged
  bridge vlan add vid 50 dev br0 self tagged
  bridge vlan add vid 50 dev eth2 pvid untagged
  bridge vlan del vid 1 dev eth2 2>/dev/null
  ip link set eth1 up
  ip link set eth2 up
  ip link set br0 up
'
```

**Lesson**: Single-attached L2Out is a SPOF. For production, you'd
want either:
- Dual-attached via vPC (external uses LACP bond to both leaves)
- BGP/EVPN-speaking external switch (but then it's not really
  "external" anymore)
- External device clustering with its own redundancy

## Skip if short on time

Exercise 4 (external failure) is the most production-relevant.
Exercise 2 (peer-link VLAN removal) teaches the VXLAN-vs-bridge
trade-off cleanly.
