# Session 8: Verification — L2Out (Extending L2VNI to External Switch)

## Pre-check: Lab is the new topology

Session 8 adds two new containers (external, host3). If you haven't
redeployed since adding the topology change:

```bash
docker ps | grep clab-vxlan-evpn
```

Expected: 8 containers (4 NX-OS + host1 + host2 + external + host3).

If you only see 6 (no external, no host3), you need to redeploy:

```bash
containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup
./scripts/deploy.sh 01-underlay
```

## Step 1: Apply Session 8

```bash
./scripts/switch.sh 08-l2out
```

Expected: ~10 sec push. "Config OK on leaf1 (found: vlan 50)".

## Step 2: Configure the external switch as a Linux bridge

The "external" container is an Alpine Linux box. Make it act as
an L2 switch by creating a bridge across its eth1 (toward leaf1)
and eth2 (toward host3):

```bash
docker exec clab-vxlan-evpn-external sh -c '
  # Create the bridge
  ip link add br0 type bridge vlan_filtering 1 2>/dev/null || true

  # Enslave eth1 (trunk to leaf1) and eth2 (access to host3)
  ip link set eth1 master br0
  ip link set eth2 master br0

  # eth1 carries VLAN 50 tagged (trunk side)
  bridge vlan add vid 50 dev eth1 tagged
  bridge vlan add vid 50 dev br0 self tagged

  # eth2 is access in VLAN 50 (untagged)
  bridge vlan add vid 50 dev eth2 pvid untagged
  bridge vlan del vid 1 dev eth2

  # Bring up everything
  ip link set eth1 up
  ip link set eth2 up
  ip link set br0 up
'
```

## Step 3: Configure host3 with an IP in VLAN 50 subnet

```bash
docker exec clab-vxlan-evpn-host3 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.50.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.50.1
'
```

## Step 4: Verify the new VLAN/VNI on leaf1

```
ssh admin@clab-vxlan-evpn-leaf1
```

```
show vlan id 50
```

Expected: VLAN 50 active. Ports include Eth1/6 (the L2Out trunk),
the peer-link Po100, and the SVI Vlan50.

```
show interface vlan 50
```

Expected: Vlan50 up, IP 10.100.50.1/24, VRF Tenant-A, anycast
gateway MAC.

```
show nve vni
```

Expected: VNI 10050 listed alongside the existing VNIs (10010,
10020, 10030, 10040, 50001, 50002). State: Up.

```
show bgp l2vpn evpn vni-id 10050
```

Expected: Type-3 inclusive multicast routes for the shared VTEP
(10.0.1.100) in L2VNI 10050.

## Step 5: Verify host3's MAC is learned on leaf1

After step 3, host3 will start sending ARP requests for its default
gateway (10.100.50.1, which is leaf1's anycast SVI). leaf1 will
learn host3's MAC.

Quick way: ping the gateway from host3:

```bash
docker exec clab-vxlan-evpn-host3 ping -c 3 10.100.50.1
```

Expected: succeeds. host3 can reach its gateway through the
external switch and Eth1/6 trunk.

Then on leaf1:

```
show mac address-table vlan 50
```

Expected: host3's MAC listed on Eth1/6 (or Po10 if it appears via
LACP, but here it's plain trunk so Eth1/6 directly).

```
show ip arp vrf Tenant-A 10.100.50.10
```

Expected: host3's IP resolved to its MAC.

## Step 6: Check that host3 is now in the EVPN fabric

leaf1 should now advertise host3's MAC as a Type-2 EVPN route. On
leaf2:

```
ssh admin@clab-vxlan-evpn-leaf2
show bgp l2vpn evpn route-type 2
```

Expected: a Type-2 entry for host3's MAC, originated from
10.0.1.100 (the shared VTEP), in L2VNI 10050.

## Step 7: The cross-fabric ping — the proof of L2Out

host1 (fabric-attached, VLAN 10, 10.100.10.10) should be able to
reach host3 (external-attached, VLAN 50, 10.100.50.10) via
inter-VLAN routing in Tenant-A.

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.50.10
```

Expected: succeeds, TTL=62.

The data path:
1. host1 (VLAN 10) sends to 10.100.50.10
2. host1's anycast gateway is leaf1's Vlan10 SVI
3. leaf1 routes inter-VLAN to Vlan50 (same VRF Tenant-A, no L3VNI)
4. leaf1's Vlan50 has host3's MAC learned via Eth1/6
5. leaf1 forwards frame out Eth1/6 to external switch
6. External switch (Linux bridge) forwards to host3 on eth2

**No VXLAN encapsulation used** for this path because host3 is
locally attached to leaf1 in the same VLAN. The fabric only uses
VXLAN when traffic must cross between leaves.

## Step 8: The cross-VLAN-via-fabric ping (more interesting)

Move host3's traffic across the fabric by having host2 (Tenant-B
via route leak) try to reach host3:

```bash
docker exec clab-vxlan-evpn-host2 ping -c 5 10.100.50.10
```

Expected: succeeds (route leak from Session 5b is still in effect).

This is more interesting because:
1. host2 (Tenant-B) on leaf2 sends to 10.100.50.10
2. leaf2 routes via the leaked route to Tenant-A
3. leaf2 needs to reach host3 — looks up EVPN Type-2 route
4. Type-2 says host3 is at VTEP 10.0.1.100 (the shared VIP)
5. leaf2 sends VXLAN-encapsulated packet to 10.0.1.100
6. The VIP belongs to the vPC pair; either leaf1 or leaf2
   receives it. If leaf1: forwards out Eth1/6 to external →
   host3. If leaf2: forwards over peer-link to leaf1 (since
   leaf1 has the local L2 connection to host3) → out Eth1/6.

Test it:

```bash
docker exec clab-vxlan-evpn-host2 ping -c 5 10.100.50.10
```

## Summary

If Steps 1-8 pass, Session 8 is verified:
- VLAN 50 created and operational on the leaves
- L2VNI 10050 in EVPN
- External switch bridging traffic between leaf1 and host3
- host3 MAC learned by EVPN fabric
- Cross-VLAN routing to host3 works (host1 → host3)
- Cross-tenant routing to host3 works (host2 → host3 via leak)

You've extended an L2VNI from the VXLAN fabric out to a non-fabric
switch. This is the foundation for integrating legacy gear into
modern data centers.

## Troubleshooting

### VLAN 50 not active on leaf1

```
show vlan id 50
```

If the VLAN doesn't show as "active": check that the cfg push
succeeded. Look at `scripts/_push.log`.

### host3 can't ping 10.100.50.1

Check the external bridge setup:

```bash
docker exec clab-vxlan-evpn-external bridge vlan
```

Should show:
- eth1: VLAN 50 tagged
- eth2: VLAN 50 untagged, pvid

If the VLAN setup is wrong, re-run the external bridge setup
commands from Step 2.

### host1 can ping 10.100.50.1 but not 10.100.50.10

That means routing to host3's subnet works (leaf1 has the local
subnet) but the L2 path to host3 is broken.

Check on leaf1:
```
show mac address-table vlan 50
```

If host3's MAC isn't there: traffic isn't reaching the leaf from
host3. Check Eth1/6 status:
```
show interface Ethernet1/6 status
```

Should be `trunk` and `connected`. If `notconnect`: clab veth
didn't materialize, redeploy needed.

### host2 → host3 fails

Most likely the route leak from Session 5b got dropped. Verify:
```
show ip route vrf Tenant-B 10.100.50.0
```

Should show route leaked from Tenant-A via Vlan50 SVI.
