# Session 8: L2Out — Extending L2VNI to External Switches

**Prerequisites**: Session 6c working (vPC + shared VTEP). Topology
change required — adds external switch and host3.

**Goal**: Extend an L2VNI (VLAN 50) out to a non-EVPN switch. The
external switch participates in VLAN 50's broadcast domain but
doesn't speak BGP-EVPN. Hosts behind the external switch appear
in the EVPN fabric as if they were directly attached.

**Lab folder**: `labs/08-l2out/`

**Estimated time**: 25-30 minutes

**Why this matters**: Real data centers always have a mix of
fabric-attached and legacy gear. L2Out is how the fabric integrates
with that legacy gear without forcing it to speak modern protocols.
A bank with VMware ESXi clusters on top-of-rack switches that
don't run EVPN still needs those VMs in the same VLAN as fabric-
attached workloads. L2Out solves this.

---

## Bring-up

**Self-contained session (Model B)** — this topology adds the
`external` switch and `host3` containers, so it deploys fresh rather
than layering on the running lab. See
[`DEPLOYMENT.md`](DEPLOYMENT.md).

```bash
cd ~/vxlan-evpn-zero-to-hero

# 1. Tear down the running lab (frees RAM, avoids node-name clashes)
containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup

# 2. Deploy this session's self-contained topology (~15 min)
./scripts/deploy.sh 08-l2out

# 3. Wait for all n9kv (healthy), then push configs
watch -n 10 'docker ps --format "{{.Names}}\t{{.Status}}" | grep clab-vxlan'
./scripts/switch.sh 08-l2out
# switch.sh prints the external-bridge + host3 setup commands. Run them,
# then the three L2Out test pings it lists.
```

---

## Mental model

A VLAN in a VXLAN fabric is mapped to a VNI. Within the fabric,
that VNI is encapsulated and tunneled between VTEPs. **At the
fabric edge**, the VNI gets unwrapped: traffic exits as plain
802.1Q-tagged Ethernet frames on a designated port.

The external switch sees this port as a regular trunk carrying a
VLAN. It doesn't know or care that the fabric uses VXLAN internally.
It just bridges traffic in that VLAN as it would for any other
neighbor.

```
host3 (in VLAN 50, behind external switch)
    │
external switch (Linux bridge, VLAN 50 trunk)
    │  (plain 802.1Q on the trunk)
leaf1 Ethernet1/6 (trunk allowing VLAN 50)
    │  (now in fabric)
VXLAN encap when traveling to other leaves
    │
leaf2 (decap, can route via Vlan50 SVI)
    │
host2 (different leaf, but reaches host3 transparently)
```

From the EVPN control plane:
- leaf1 learns host3's MAC on Eth1/6 (normal L2 learning)
- leaf1 advertises this MAC as an EVPN Type-2 route in VNI 10050
- Other leaves install host3's MAC, knowing it's reachable via
  the shared VTEP 10.0.1.100
- When traffic from any leaf needs to reach host3, it's
  VXLAN-encap'd to 10.0.1.100, decap'd at leaf1, and forwarded
  out Eth1/6

---

## Architecture

```
                spine1            spine2
                  │                 │
        ┌─────────┴─────────┬───────┴────────┐
        │                   │                │
      leaf1               leaf2              │
        │                   │                │
   ┌────┴──┬───────┐  ┌─────┴──┬──────┐      │
   │       │       │  │        │      │      │
 host1   host3   ...  host2  (vPC to host1)  │
 (VLAN  via      │    (VLAN
  10)  external  │     30)
        switch   │
                 │
              Eth1/6 trunk (VLAN 50)
                 │
              external (Linux bridge)
                 │
              host3 (VLAN 50, 10.100.50.10)
```

---

## What we add (on top of Session 6c)

**Topology changes** (in topology.clab.yml):
- New container: `external` (Linux container running as L2 bridge)
- New container: `host3` (Linux container, end host)
- New link: `leaf1:eth6 ↔ external:eth1` (trunk, the L2Out)
- New link: `external:eth2 ↔ host3:eth1` (access)

**Config changes on both leaves**:
- New VLAN 50 mapped to VNI 10050
- Anycast SVI Vlan50 in Tenant-A (IP 10.100.50.1/24)
- EVPN block for VNI 10050
- NVE member VNI 10050
- VLAN 50 added to peer-link allowed list

**Config changes only on leaf1**:
- Eth1/6 configured as trunk with VLAN 50

**External switch**: Linux bridge with VLAN filtering, set up
post-deployment via docker exec (not in clab cfg).

---

## Design decisions

**Decision 1: Single-attached vs dual-attached external**

In Session 8 we go **single-attached** (external connects to
leaf1 only). Why?

- Cleanest L2Out teaching example
- No vPC + LACP complexity layered on top
- Real production sometimes uses single-attached for less-critical
  workloads

Dual-attached L2Out (external dual-homed via vPC to both leaves)
is a real pattern for critical workloads. Cost: another LACP bond
configuration on the external side. We can demo this as a Session
8b later if time permits.

**Decision 2: External as Linux bridge container**

We use a Linux Alpine container with kernel bridge + VLAN filtering
as the "external switch." Cheaper than another N9000v (which
costs ~15 min boot + significant RAM). Behaviorally equivalent
for the L2 trunking we need to demonstrate.

In a real bank deployment, the "external" might be:
- A Cisco Catalyst aggregation switch
- An Arista 7050 ToR running standard ECMP
- A Juniper EX series
- A VMware vSwitch on an ESXi host
- Even a Linux bridge on a server with bonds

All look the same from leaf1's perspective: a plain 802.1Q
trunk speaker.

**Decision 3: New VLAN 50, not reusing existing**

We create a new VLAN/VNI rather than extending an existing one
(like VLAN 10, where host1 lives). Why?

- Cleaner teaching separation
- No interference with vPC bond traffic on VLAN 10
- Realistic: real L2Out usually segregates external traffic from
  fabric-internal traffic

**Decision 4: Tenant-A, not a new tenant**

VLAN 50 is in Tenant-A (alongside VLAN 10/20). We could put it in
a new VRF if we wanted strict isolation between external and
fabric-internal hosts. We don't — the use case here is "extend
existing Tenant-A out to legacy gear," not "isolate external
traffic from fabric."

For real deployments, both patterns occur. Tenant separation is
a policy decision based on trust level of the external network.

---

## Key tests after deployment

### Test 1: VLAN/VNI operational

```
show vlan id 50
show nve vni
show bgp l2vpn evpn vni-id 10050
```

VNI 10050 active in EVPN, advertising via shared VTEP 10.0.1.100.

### Test 2: External-to-fabric ping

```bash
docker exec clab-vxlan-evpn-host3 ping -c 3 10.100.50.1
```

host3 → its gateway (anycast SVI on leaves) succeeds.

### Test 3: Fabric-to-external ping

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10
```

host1 (fabric-attached, VLAN 10) → host3 (external, VLAN 50) via
inter-VLAN routing in Tenant-A.

### Test 4: Cross-tenant via leak + cross-VLAN to external

```bash
docker exec clab-vxlan-evpn-host2 ping -c 3 10.100.50.10
```

host2 (Tenant-B) → host3 (Tenant-A, external) — exercises the route
leak from Session 5b combined with the new L2Out path. Traffic
travels VXLAN-encap'd from leaf2 to leaf1, decap'd, forwarded
out Eth1/6 to external, then to host3.

---

## Production patterns we're foreshadowing

**MLAG to the external switch**: Extending L2Out across both leaves
via vPC for chassis redundancy. The external runs LACP toward both
leaves; the leaves treat the trunk as a vPC member port.

**VLAN translation at the boundary**: Sometimes fabric VLAN 50
needs to map to external VLAN 100 on the legacy side. NX-OS
supports `switchport vlan mapping` for this. Common when merging
fabrics with different VLAN ID schemes.

**Storm control on L2Out**: External switches sometimes flood
broadcasts unexpectedly. Production deployments set `storm-control
broadcast` on the L2Out trunk to limit blast radius.

**MAC mobility events**: When a workload migrates between fabric-
attached and external-attached (e.g., vMotion across racks), EVPN
generates MAC mobility events. The receiving leaf re-advertises
the MAC with an incremented mobility sequence number. The fabric
converges automatically.

---

## What you should be able to explain after Session 8

1. Why a fabric needs L2Out (legacy/external integration)
2. How L2Out works at the leaf (regular trunk port + EVPN
   advertisement of learned MACs)
3. The trade-off between single-attached and dual-attached L2Out
4. What an external switch is doing differently from a fabric leaf
   (no BGP-EVPN, just standard L2 bridging)
5. How traffic from a fabric host reaches an external host across
   the fabric (anycast gateway → VXLAN to remote VTEP → decap →
   trunk → external)

---

## Next

Session 9: L3Out — the L3 equivalent of L2Out. Connect a tenant
VRF to an external router (typically a WAN router or a firewall).
The external speaks BGP or OSPF with a leaf, learning about fabric
prefixes and advertising external prefixes back in. The pattern
for "fabric to internet" or "fabric to private WAN" connectivity.
