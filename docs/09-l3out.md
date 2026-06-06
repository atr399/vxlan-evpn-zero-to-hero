# Session 9: L3Out — Tenant VRF to External Router via eBGP

**Prerequisites**: Session 8 working. Topology change required —
adds extrouter (FRR) and host_internet containers.

**Goal**: Establish eBGP routing exchange between Tenant-A VRF on
leaf1 and an external router. External destinations become
reachable from any fabric leaf via EVPN Type-5 propagation. Fabric
prefixes become reachable from external networks.

**Lab folder**: `labs/09-l3out/`

**Estimated time**: 30-35 minutes

**Why this matters**: Every data center connects to something
outside the fabric — WAN, internet, firewalls, partner networks,
DMZ. L3Out is how that connectivity is established. It's the
fabric's "edge to the world."

---

## Mental model

In Session 8 we extended L2 (a single VLAN) out to a non-EVPN
switch. In Session 9 we extend L3 (a whole VRF's routing table)
out to a non-EVPN router.

```
                Tenant-A VRF
                    │
        ┌───────────┼─────────────────┐
        │           │                  │
      leaf1       leaf2                │
        │                              │
   Eth1/7                              │
   (in Tenant-A,                       │
    192.0.2.0/31)                      │
        │                              │
   eBGP AS 65000 ↔ AS 65100             │
        │                              │
   extrouter (FRR)                      │
        │                              │
   eth2 (203.0.113.1/24)               │
        │                              │
   host_internet (203.0.113.10/24)     │
        ↑                              │
        │                              │
   Reachable from anywhere in Tenant-A?
   YES — via EVPN Type-5 propagation
```

The pattern from the fabric's perspective:
1. leaf1 has a routed interface in VRF Tenant-A, talking eBGP to
   extrouter
2. leaf1 learns external prefixes (e.g., 203.0.113.0/24)
3. leaf1 redistributes those into EVPN as Type-5 routes
4. Other leaves install the Type-5 routes in their Tenant-A RIB
5. They reach external destinations via VXLAN to leaf1 (the "border
   leaf"), which then forwards to extrouter

Symmetric: leaf1 advertises fabric prefixes (10.100.10.0/24 etc.)
to extrouter. External networks can reach fabric hosts back through
leaf1.

---

## Architecture decisions for this session

**Decision 1: eBGP, not OSPF or static**

eBGP is the production standard for data center L3Out:
- Flexible policy control (route-maps, prefix-lists, communities)
- Scales to large external networks
- Same protocol as our underlay/overlay — your friends know it

OSPF L3Out exists in older designs. Static routes work for small,
stable external connectivity. We pick eBGP because it's what real
fabrics deploy.

**Decision 2: Single-attached to leaf1**

One leaf serves as "border leaf" for Tenant-A's L3Out. Other leaves
reach external via EVPN Type-5 → VXLAN to leaf1.

Production typically uses **dual-attached L3Out** for redundancy:
both leaves have their own eBGP sessions to (separate) external
routers. We'll mention this as a production pattern but not deploy
it in the lab to keep complexity manageable.

**Decision 3: Tenant-A only**

We extend only Tenant-A out. Tenant-B has no L3Out in this
session. That said — Session 5b's route leak means Tenant-B hosts
CAN reach external destinations by leaking to Tenant-A first.

**Decision 4: Routed physical interface (not sub-interface)**

leaf1's Eth1/7 becomes a routed L3 port assigned to Tenant-A VRF.
Standard pattern. Sub-interfaces (`Ethernet1/7.50`) are also valid
when you need multiple VRFs sharing one physical port — but we
don't here.

**Decision 5: External AS 65100**

Clearly distinct from any fabric ASN. Could be anything; we pick
65100 because it's outside our underlay/overlay AS range.

**Decision 6: FRR as the external router**

FRR (Free Range Routing) is a real BGP/OSPF stack widely used in
production. Lightweight, free, runs in a Docker container. From
leaf1's perspective, indistinguishable from a Cisco/Arista/Juniper
external router speaking standard eBGP.

In your real production fabric, the "external router" might be:
- A Cisco ASR1000 connecting to your WAN provider
- A Juniper MX series serving as your DMZ aggregator
- A Palo Alto firewall participating in BGP
- A cloud-provider's BGP edge (e.g., AWS Direct Connect router)

All look the same to the fabric — an eBGP neighbor in a tenant VRF.

---

## What we add on top of Session 8

**Topology changes** (in topology.clab.yml):
- New container: `extrouter` (using `frrouting/frr:latest` image)
- New container: `host_internet` (Linux, represents external host)
- New link: `leaf1:eth7 ↔ extrouter:eth1` (the L3Out)
- New link: `extrouter:eth2 ↔ host_internet:eth1`

**Config changes on leaf1 only** (leaves and spines unchanged
otherwise):
- New routed interface Eth1/7 in VRF Tenant-A, IP 192.0.2.0/31
- eBGP neighbor 192.0.2.1 (AS 65100) under `vrf Tenant-A` BGP context

**FRR config on extrouter**:
- eBGP to leaf1 (AS 65000)
- Advertises 203.0.113.0/24
- Black-hole route to 203.0.113.0/24 (Null0) so the route exists
  to be advertised

**No spine changes**: spines don't care about external prefixes
directly — they just propagate EVPN routes (including the Type-5
that carries 203.0.113.0/24).

**No leaf2 changes**: leaf2 learns 203.0.113.0/24 entirely through
EVPN Type-5 from leaf1. No L3Out-specific config needed on leaf2.

---

## Why EVPN Type-5 matters here

**Type-5** is the EVPN route type for IP prefixes (not just MACs or
hosts). When leaf1 receives 203.0.113.0/24 from extrouter via eBGP,
NX-OS sees it inside Tenant-A VRF. The `advertise l2vpn evpn` line
under the VRF tells NX-OS to **redistribute these routes into EVPN
as Type-5**.

Other leaves see the Type-5 route, install it in their Tenant-A
RIB. Now leaf2 knows: "to reach 203.0.113.0/24, send VXLAN to
10.0.1.100 (the shared VTEP); leaf1 will decap and forward to
extrouter."

This is "**asymmetric IRB**" at the EVPN layer — but symmetric
forwarding at the fabric layer because Tenant-A's L3VNI 50001
handles the inter-leaf transport.

---

## Key tests after deployment

### Test 1: eBGP session up

```
show bgp vrf Tenant-A ipv4 unicast summary
```

Expected: neighbor 192.0.2.1 (AS 65100) in Established state, with
1+ prefix received.

### Test 2: External route in Tenant-A RIB on leaf1

```
show ip route 203.0.113.0/24 vrf Tenant-A
```

Expected: via 192.0.2.1, tag 65100, bgp-external.

### Test 3: EVPN Type-5 propagation

```
show bgp l2vpn evpn route-type 5
```

Expected: 203.0.113.0/24 entry visible. RT matches Tenant-A's
L3VNI (65000:50001).

### Test 4: leaf2 reaches external via VXLAN

```
show ip route 203.0.113.0/24 vrf Tenant-A
```

(On leaf2.) Expected: via 10.0.1.100 (shared VTEP), encap: VXLAN,
segid: 50001.

### Test 5: End-to-end ping

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
docker exec clab-vxlan-evpn-host2 ping -c 3 203.0.113.10
```

Both should succeed. host2's path goes through the Session 5b
route leak (Tenant-B → Tenant-A → external).

### Test 6: External can reach fabric

```bash
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.10.10
```

Expected: succeeds. extrouter learned fabric subnets via eBGP from
leaf1.

---

## Production patterns we're foreshadowing

**Dual-attached L3Out**: For redundancy, both leaves run their own
eBGP sessions to (typically separate) external routers. EVPN
handles failover automatically — if leaf1's L3Out dies, Type-5 from
leaf2 takes over.

**BFD on the eBGP session**: Default BGP timers (180s hold) are too
slow for production. BFD (Bidirectional Forwarding Detection)
provides sub-second neighbor failure detection. Single command:
`neighbor X.X.X.X bfd` on both sides.

**Route policy / filtering**: Production L3Out ALWAYS has policy.
Common policies:
- Inbound from external: deny default-route (unless intentional),
  prefix-list of expected routes, community-based filtering
- Outbound to external: only advertise fabric-managed prefixes,
  deny re-advertising what we just learned

**Route reflection between border leaves**: When you have multiple
L3Out points, you might want each border leaf to know about other
border leaves' external routes. EVPN handles this naturally via
Type-5 — no extra config needed for this case.

**Default route injection**: Some L3Outs inject a default route
(0.0.0.0/0) into the fabric so internal hosts have a path to "the
internet." This is policy-driven and requires careful configuration
to avoid loops.

**VRF leaking with L3Out**: Combine Session 5b (VRF leaking) with
this session: Tenant-B hosts can reach external networks via
Tenant-A's L3Out, even though Tenant-B has no L3Out itself. Useful
for shared services (DNS, NTP, etc. behind a single L3Out).

---

## What you should be able to explain after Session 9

1. The difference between L2Out (Session 8) and L3Out (this session)
2. What a "border leaf" is in a VXLAN-EVPN fabric
3. How EVPN Type-5 routes are different from Type-2 routes
4. Why other leaves don't need L3Out config — they learn external
   routes via EVPN
5. The trade-off between single-attached and dual-attached L3Out
6. Why production L3Out requires BFD and route policy

---

## Next

Session 10: Multi-Pod. Multiple VXLAN-EVPN pods stitched together
via an IPN (Inter-Pod Network). Each pod has its own spine-leaf
fabric; pods exchange routes via the IPN. The pattern for scaling
fabrics beyond a single rack-row or single building.

Session 11: Multi-Site. Geographically separated fabrics connected
via DCI (Data Center Interconnect). Adds Border Gateways (BGWs)
that re-originate routes across site boundaries. The pattern for
active-active multi-region data centers.
