# Session 9: Verification — L3Out (eBGP to External Router in Tenant-A VRF)

## Pre-check: Topology includes new nodes

```bash
docker ps | grep clab-vxlan-evpn
```

Expected: 10 containers — 4 NX-OS + host1, host2, external, host3,
**extrouter, host_internet**.

If only 8 visible, redeploy needed:

```bash
containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup
./scripts/deploy.sh 01-underlay
```

## Step 1: Apply Session 9

```bash
./scripts/switch.sh 09-l3out
```

Expected: ~10 sec push. "Config OK on leaf1 (found: neighbor 192.0.2.1)".

## Step 2: Bootstrap the external router (FRR)

The extrouter container needs its FRR config and IP addressing
loaded post-deploy:

```bash
# Apply IP addresses to extrouter's interfaces
docker exec clab-vxlan-evpn-extrouter sh -c '
  ip addr add 192.0.2.1/31 dev eth1
  ip addr add 203.0.113.1/24 dev eth2
  ip link set eth1 up
  ip link set eth2 up
'

# Load FRR config and restart
docker cp labs/09-l3out/extrouter/frr.conf clab-vxlan-evpn-extrouter:/etc/frr/frr.conf
docker cp labs/09-l3out/extrouter/daemons clab-vxlan-evpn-extrouter:/etc/frr/daemons
docker exec clab-vxlan-evpn-extrouter sh -c '
  /usr/lib/frr/frrinit.sh restart || /usr/lib/frr/frr restart
'

# Verify FRR started
docker exec clab-vxlan-evpn-extrouter vtysh -c "show ip bgp summary"
```

## Step 3: Configure host_internet

```bash
docker exec clab-vxlan-evpn-host_internet sh -c '
  ip addr flush dev eth1
  ip addr add 203.0.113.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 203.0.113.1
'
```

## Step 4: Verify eBGP peering on leaf1

```
ssh admin@clab-vxlan-evpn-leaf1
show bgp vrf Tenant-A ipv4 unicast summary
```

Expected:
```
BGP router identifier 10.0.0.21, local AS number 65000
Neighbor      V    AS    MsgRcvd    MsgSent  ...  State/PfxRcd
192.0.2.1     4 65100        X         X          1
```

State should show **1 prefix received** — that's `203.0.113.0/24`
from extrouter.

If `State: Idle` or `Active`: eBGP session isn't up. Check:
- `show interface Ethernet1/7` (should be UP)
- `ping 192.0.2.1 vrf Tenant-A` (should succeed)
- Verify FRR is running: `docker exec clab-vxlan-evpn-extrouter
  vtysh -c "show ip bgp summary"`

## Step 5: Verify the external route is in Tenant-A

```
show ip route 203.0.113.0/24 vrf Tenant-A
```

Expected:
```
203.0.113.0/24, ubest/mbest: 1/0
    *via 192.0.2.1, [20/0], 00:00:30, bgp-65000, external, tag 65100
```

leaf1 has the external route via eBGP, tagged with AS 65100.

## Step 6: Verify EVPN Type-5 propagation

leaf1 should redistribute the external route into EVPN as a Type-5
(IP prefix) route, so leaf2 also learns it.

On leaf1:
```
show bgp l2vpn evpn route-type 5
```

Look for an entry for `203.0.113.0/24` — should be present with
RT matching Tenant-A's L3VNI (65000:50001).

On leaf2:
```
ssh admin@clab-vxlan-evpn-leaf2
show ip route 203.0.113.0/24 vrf Tenant-A
```

Expected:
```
203.0.113.0/24, ubest/mbest: 1/0
    *via 10.0.1.100%default, [200/0], ... bgp-65000, internal,
        tag 65000, segid: 50001, encap: VXLAN
```

leaf2 reaches 203.0.113.0/24 via VXLAN through the shared VTEP
(10.0.1.100), pointing back at leaf1. Symmetric IRB with L3VNI
50001 (Tenant-A).

## Step 7: The end-to-end ping — fabric host to "the internet"

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
```

Expected: succeeds, TTL=61 (host1 → leaf1 → extrouter →
host_internet = 3 L3 hops, so TTL decremented 3 times from 64).

If from host2 (different leaf, Tenant-B, but with Session 5b
route leak active):
```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 203.0.113.10
```

Expected: succeeds. Path:
1. host2 → leaf2 (Tenant-B SVI)
2. leaf2 follows leaked route to Tenant-A
3. leaf2 sees 203.0.113.0/24 via EVPN Type-5 → VTEP 10.0.1.100
4. VXLAN to leaf1
5. leaf1 decap, route to extrouter via eBGP
6. extrouter → host_internet

## Step 8: Reverse — host_internet reaches fabric

```bash
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.10.10
```

This works only if extrouter has a route back to 10.100.10.0/24.
We rely on eBGP to advertise fabric prefixes to extrouter.

On leaf1:
```
show bgp vrf Tenant-A ipv4 unicast neighbors 192.0.2.1 advertised-routes
```

Expected: prefixes 10.100.10.0/24, 10.100.20.0/24, 10.100.50.0/24
(Tenant-A's connected subnets) are being advertised to extrouter.

On extrouter:
```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "show ip route"
```

Expected: routes for 10.100.10.0/24 etc., next-hop 192.0.2.0.

If routes are present, the reverse ping succeeds.

## Summary

If Steps 1-8 pass, Session 9 is verified:
- eBGP session between leaf1 (Tenant-A) and extrouter (AS 65100)
- External route 203.0.113.0/24 learned in Tenant-A VRF
- EVPN Type-5 propagates external route to all leaves
- Other leaves reach external via VXLAN to leaf1 (border leaf pattern)
- Fabric hosts can reach external hosts
- External hosts can reach fabric hosts

This is the fabric-to-WAN connectivity pattern used in every
production data center.

## Troubleshooting

### FRR doesn't start in extrouter

Verify the container is running:
```bash
docker ps | grep extrouter
docker logs clab-vxlan-evpn-extrouter --tail 20
```

If FRR isn't running, try manual start:
```bash
docker exec clab-vxlan-evpn-extrouter /usr/lib/frr/frrinit.sh start
```

### BGP session stuck in Idle/Active

Verify connectivity at the IP layer:
```
ssh admin@clab-vxlan-evpn-leaf1
ping 192.0.2.1 vrf Tenant-A
```

If ping fails: check Eth1/7 status, verify IP addressing.

If ping works but BGP doesn't form: FRR config not loaded properly.
Re-run Step 2.

### EVPN Type-5 not seen on leaf2

leaf1's Tenant-A BGP config must include `advertise l2vpn evpn`
to redistribute eBGP routes into EVPN.

Verify:
```
show running-config | section "vrf Tenant-A"
```

Should show `advertise l2vpn evpn` under the VRF's IPv4 unicast AF.

### Asymmetric reachability (fabric→ext OK, ext→fabric fails)

extrouter doesn't have a route back. Check:
```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "show ip route"
```

If fabric subnets missing: leaf1 isn't advertising them. Could be
missing `redistribute direct route-map ALL_ROUTES` under the VRF.
