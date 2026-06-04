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

Expected: ~10 sec push. "Config OK on leaf1 (found: vn-segment 10050)".

## Step 2: Configure the external switch (Linux bridge via VLAN sub-interface)

The "external" container is an Alpine Linux box. Alpine doesn't ship
the `bridge` command, so we use VLAN sub-interface approach instead
of VLAN-filtering bridge:

```bash
docker exec clab-vxlan-evpn-external sh -c '
  # Tear down anything prior
  ip link set br0 down 2>/dev/null
  ip link delete br0 2>/dev/null
  ip link delete eth1.50 2>/dev/null

  # Create VLAN 50 sub-interface on eth1 (trunk to leaf1)
  ip link add link eth1 name eth1.50 type vlan id 50

  # Simple bridge (VLAN handled by sub-interface, not bridge filtering)
  ip link add br0 type bridge

  # Bridge eth1.50 (tagged VLAN 50) with eth2 (access to host3)
  ip link set eth1.50 master br0
  ip link set eth2 master br0

  # Bring up
  ip link set eth1 up
  ip link set eth1.50 up
  ip link set eth2 up
  ip link set br0 up
'
```

## Step 3: Configure host3 with VLAN 50 subnet IP

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

Expected: VLAN 50 active. Ports include Eth1/6 (L2Out trunk),
peer-link members (Po100, Eth1/4), and the SVI Vlan50.

```
show interface vlan 50
```

Expected: Vlan50 up, IP 10.100.50.1/24, VRF Tenant-A, anycast
gateway MAC.

```
show nve vni
```

Expected: VNI 10050 listed alongside existing VNIs. State: Up.

```
show bgp l2vpn evpn vni-id 10050
```

Expected: Type-3 inclusive multicast routes for the shared VTEP
(10.0.1.100) in L2VNI 10050.

## Step 5: External-to-gateway ping

```bash
docker exec clab-vxlan-evpn-host3 ping -c 3 10.100.50.1
```

Expected: succeeds, TTL=255 (host3 reaching local-subnet gateway).

After this, on leaf1:

```
show mac address-table vlan 50
```

Expected: host3's MAC listed on Eth1/6.

```
show ip arp vrf Tenant-A 10.100.50.10
```

Expected: host3's IP resolved to its MAC.

## Step 6: Fabric-to-external ping

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10
```

Expected: succeeds, TTL=62 (inter-VLAN routing in Tenant-A).

Data path:
1. host1 (VLAN 10) → leaf1's Vlan10 SVI (anycast gateway)
2. leaf1 routes inter-VLAN to Vlan50 (both VLANs in Tenant-A, no L3VNI needed)
3. leaf1's Vlan50 has host3's MAC on Eth1/6
4. leaf1 forwards out Eth1/6 to external switch
5. External bridge forwards via eth2 to host3

## Step 7: EVPN learning across leaves

On leaf2:

```
ssh admin@clab-vxlan-evpn-leaf2
show bgp l2vpn evpn route-type 2
```

Expected: A Type-2 entry for host3's MAC, originated from
10.0.1.100 (shared VTEP), in L2VNI 10050. This means leaf2 has
learned host3 via EVPN.

## Step 8: Cross-tenant + L2Out ping

```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 10.100.50.10
```

Expected: succeeds.

Data path:
1. host2 (Tenant-B, on leaf2) → 10.100.50.10
2. leaf2 looks up via route-leak from Session 5b → Tenant-A
3. leaf2 needs to reach host3 — checks EVPN Type-2
4. Type-2 says host3 is at VTEP 10.0.1.100 (shared VIP)
5. leaf2 VXLAN-encaps to 10.0.1.100
6. Packet arrives at either leaf1 or leaf2 (anycast). If leaf2:
   forwards over peer-link to leaf1. Either way ends at leaf1.
7. leaf1 decaps, forwards out Eth1/6 to external → host3

## Summary

If Steps 1-8 pass, Session 8 is verified:
- VLAN 50 created and operational on the leaves
- L2VNI 10050 in EVPN
- External Linux bridge bridging traffic between leaf1 and host3
- host3 MAC learned by EVPN fabric
- Inter-VLAN routing to host3 works (host1 → host3)
- Cross-tenant routing to host3 works (host2 → host3 via leak)

You've extended an L2VNI from the VXLAN fabric out to a non-fabric
switch. This is the foundation for integrating legacy gear into
modern data centers.

## Troubleshooting

### "exec: bridge: executable file not found"

Alpine doesn't ship the `bridge` command. The VLAN sub-interface
approach above sidesteps this — we don't use `bridge vlan ...`
commands.

### host3 can't ping 10.100.50.1

Check the external setup:
```bash
docker exec clab-vxlan-evpn-external ip link show
```

Expected: br0 exists, eth1.50 exists with `master br0`, eth2 with
`master br0`.

If anything is missing, re-run the Step 2 commands.

### host1 can ping 10.100.50.1 but not 10.100.50.10

That means routing to host3's subnet works (leaf1 has the local
subnet) but the L2 path to host3 is broken.

On leaf1:
```
show mac address-table vlan 50
```

If host3's MAC isn't there: check Eth1/6 status:
```
show interface Ethernet1/6 status
```

Should be `trunk` and `connected`.

### host2 → host3 fails

Verify route leak still in place:
```
show ip route vrf Tenant-B 10.100.50.0
```

Should show route leaked from Tenant-A via Vlan50 SVI.
