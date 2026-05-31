# Session 4: Anycast Gateway + Symmetric IRB

**Prerequisites**: Session 3 working. host1 can ping host2 over an
L2VNI. The fabric has BGP-EVPN distributing Type-2 and Type-3 routes.

**Goal**: Give every leaf an identical first-hop gateway IP for VLAN
10 (anycast), and add a second VLAN (VLAN 20) so we can route between
them across the fabric. By the end, you'll have hosts in different
subnets talking to each other through the fabric — and a packet
capture proving the routing happens on the local leaf before VXLAN
encap.

**Lab folder**: [`labs/04-anycast-gw`](../labs/04-anycast-gw/)

**Estimated time**: 60 minutes — this session has two new big ideas
(anycast + symmetric IRB), several configs, and a packet capture that
makes the concepts concrete.

---

## Mental model

In Session 3, the fabric was one big virtual LAN. Hosts talked
host-to-host at Layer 2 over VXLAN. They had no gateway because they
didn't need one — same subnet, no routing.

Session 4 introduces the **fabric as a router**. Every leaf is willing
to be the gateway for VLAN 10. They all use the **same** IP
(10.100.10.1) and the **same** MAC. When host1 ARPs for its gateway,
its local leaf replies. When host1 moves to a different leaf, that
leaf replies — same IP, same MAC, host doesn't notice.

Picture it this way:
- **Without anycast**: every subnet has one router somewhere. To reach
  another subnet, your traffic must travel to that router, even if it's
  on the far side of the data center.
- **With anycast**: every leaf hosts every gateway. Routing happens at
  the first hop. Traffic takes the shortest path through the fabric.

> **The big shift**: this is when VXLAN-EVPN stops being "L2 stretch"
> and becomes "fully distributed routing fabric." You're not extending
> a VLAN anymore. You're letting tenant subnets exist everywhere
> simultaneously, with the fabric routing between them.

The second concept — **symmetric IRB** — answers: when traffic moves
between VLAN 10 and VLAN 20 across leaves, where does the routing
happen? Three choices:

1. **Centralized routing**: traffic from leaf1 goes to a central router,
   gets routed, comes back. The "go-to-the-data-center-edge-and-back"
   problem.
2. **Asymmetric IRB**: ingress leaf routes from L3 to L2, then
   encapsulates in the destination VLAN's L2VNI. Different VNIs for
   sending vs. return traffic.
3. **Symmetric IRB**: routing happens on the ingress leaf into a
   dedicated **L3VNI**, traverses the fabric in that L3VNI, and is
   routed again on egress. Same VNI both directions — symmetric.

Symmetric IRB is the modern standard. We'll use it because:
- It scales better (one L3VNI per VRF, regardless of how many VLANs)
- It makes troubleshooting symmetric (the path is the same both ways)
- It's required for inter-VRF routing in Session 5

This session lays the foundation: one VRF, two VLANs, one L3VNI. Same
VRF for both VLANs, so the routing is intra-VRF. Session 5 adds a
second VRF for proper inter-tenant isolation.

---

## What's an anycast gateway?

A regular gateway has one IP on one router. Hosts ARP for that IP, get
the router's MAC, send traffic.

An **anycast gateway** is the same IP on **multiple** routers
simultaneously. Cisco gives it a special common MAC (called the
"distributed gateway MAC" — usually `0000.2222.3333` or a vendor-defined
value). Every leaf with the same VLAN configured has the same gateway
IP and the same gateway MAC.

When host1 ARPs for its gateway:
1. host1 broadcasts ARP "who has 10.100.10.1?"
2. leaf1 (its local leaf) replies with the anycast MAC
3. host1 caches the MAC and sends all its inter-subnet traffic to it
4. leaf1 receives that traffic, routes it (it's a router for this VRF
   on this VLAN), encapsulates in the L3VNI, sends to the egress leaf

If host1 moves to leaf2 (e.g., vMotion in VMware), leaf2 now hosts the
same gateway with the same MAC. host1's ARP cache is still valid. The
host literally does not notice it moved.

> **Why one anycast MAC for everyone**: NX-OS uses a globally
> configurable distributed gateway MAC under `fabric forwarding`.
> Every leaf in the fabric uses this MAC for every anycast gateway.
> One MAC, used for every anycast IP, on every leaf. It's the same
> MAC across the entire fabric — and that's the point.

## Design decisions in this session

### Decision 1: VRF for tenant traffic

Up to now, host traffic lived in the default VRF (along with the
underlay). Session 4 introduces a tenant VRF — **Tenant-A**. This
separates:
- Underlay IP routing (default VRF)
- Tenant overlay routing (Tenant-A VRF)

The two VRFs share the same physical leaves but have completely
separate routing tables. host1's traffic to host2's gateway routes
within Tenant-A. The underlay BGP/OSPF traffic routes in default VRF.

This is a fundamental VXLAN-EVPN pattern: **VRFs separate tenants.**
Session 5 adds a second VRF (Tenant-B) and demonstrates true tenant
isolation.

### Decision 2: One L3VNI per VRF

Every VRF needs an L3VNI — the fabric-wide identifier used when
traffic is in the routed (L3) plane between leaves.

From `common/ipplan.md`:
- VRF Tenant-A maps to L3VNI 50001

Convention: L2VNIs are 10000+VLAN, L3VNIs are 50000+tenant-index.
This makes it visible at a glance: VNI 10010 = L2, VNI 50001 = L3.

Like L2VNIs, L3VNIs need an RD and RT. The L3VNI's RT controls which
leaves participate in this VRF's routing.

### Decision 3: SVI (Switched Virtual Interface) with `fabric forwarding mode anycast-gateway`

For each VLAN that needs L3, we create an SVI (`interface Vlan10`).
This SVI:
- Has the gateway IP (10.100.10.1)
- Lives inside the tenant VRF (`vrf member Tenant-A`)
- Has the magic line `fabric forwarding mode anycast-gateway` — this
  enables anycast behavior on the SVI

Without that one line, the SVI would be a regular SVI with regular ARP
behavior. With it, the SVI uses the fabric-wide anycast MAC and
suppresses ARP responses for IPs the EVPN control plane already knows
about. The line is small; the consequences are profound.

### Decision 4: ARP suppression

Anycast gateways enable **ARP suppression**. When a leaf knows (via
EVPN Type-2 routes) the MAC for an IP, and a host ARPs for that IP,
the leaf replies locally instead of flooding the ARP to the fabric.

This is enormous for scale. Without it, every ARP gets flooded to
every leaf in the fabric (via ingress replication to every VTEP).
With it, ARPs stay local most of the time. In a 100-leaf fabric this
is the difference between "fabric works" and "fabric melts."

ARP suppression is automatically enabled when you enable anycast
gateway. You just see fewer ARP broadcasts in the wild.

### Decision 5: The advertise-pip / advertise-virtual-rmac knobs

When a leaf advertises a Type-5 route (IP prefix) via EVPN, it needs to
say "the next-hop for this prefix is me." With anycast gateway, **every
leaf** that has the SVI configured could equally be the next-hop. The
fabric uses the leaf's **PIP** (Primary IP — its loopback1) as the
next-hop, not the anycast IP.

The line `advertise-pip` under BGP EVPN tells the leaf to put its
own PIP as next-hop on EVPN Type-5 advertisements, regardless of
which interface originated the route. This is what makes anycast
gateway work correctly for inter-subnet routing.

## What you'll build

**Same fabric, additional config on leaves**:

1. Configure the distributed gateway MAC (under `fabric forwarding`)
2. Create VRF Tenant-A, with an associated L3VNI 50001
3. Map VLAN 20 to L2VNI 10020 (we add a second VLAN this session)
4. Create SVI for VLAN 10 (anycast gateway 10.100.10.1)
5. Create SVI for VLAN 20 (anycast gateway 10.100.20.1)
6. Add the L3VNI under BGP EVPN with RT/RD
7. Add member VNIs to nve1 for VNI 50001 (L3) and VNI 10020 (L2)
8. Add `advertise-pip` to BGP

**Hosts**:
- host1 stays on VLAN 10, gets a gateway IP `10.100.10.1`
- host2 moves to VLAN 20 (a different subnet), gets a gateway IP
  `10.100.20.1`
- After config: host1 in 10.100.10.0/24 should ping host2 in
  10.100.20.0/24, with routing happening on each leaf

(This is the moment where "L2 stretch" becomes "L3 fabric.")

## Deploying

```bash
containerlab destroy -t labs/03-l2vni/topology.clab.yml --cleanup
./scripts/deploy.sh 04-anycast-gw
```

Usual 15-25 min boot. Same NX-OS quirks as before.

## Configuring the hosts (manual again)

```bash
# host1: VLAN 10, gateway 10.100.10.1
docker exec clab-vxlan-evpn-host1 sh -c "ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up && ip route add default via 10.100.10.1"

# host2: VLAN 20, gateway 10.100.20.1
docker exec clab-vxlan-evpn-host2 sh -c "ip addr add 10.100.20.10/24 dev eth1 && ip link set eth1 up && ip route add default via 10.100.20.1"
```

> **Note the topology change**: leaf2 now has VLAN 20 on Eth1/3 instead
> of VLAN 10. The host2 IP is in 10.100.20.0/24. See the leaf2 config.

## The moment of truth (with packet capture)

This session has **two** moments of truth. Capture both.

**First moment**: host1 (VLAN 10) pings its own gateway. Proves anycast
works.

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1
```

Should succeed. The reply comes from leaf1 (host1's local leaf) using
the anycast MAC.

**Second moment**: host1 pings host2. Crossing subnets, crossing leaves.

In one VS Code terminal, start a capture on leaf1's uplink:

```bash
./scripts/capture.sh leaf1 eth1 04-anycast-cross-subnet 'udp port 4789'
```

In another terminal, trigger the traffic:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

If everything works:
- The ping succeeds
- The capture has VXLAN frames, but with **VNI 50001** (the L3VNI),
  not VNI 10010 or 10020. That's symmetric IRB in action — routing
  happens locally, traffic crosses the fabric in the L3VNI.

The capture stays in `labs/04-anycast-gw/pcaps/` for you (and your
friends) to open in Wireshark and study.

## What to verify

See [`labs/04-anycast-gw/verify.md`](../labs/04-anycast-gw/verify.md).
New things to check:

- Distributed gateway MAC is configured (`show fabric forwarding`)
- SVIs are in the right VRF and have anycast mode
- L3VNI is up (`show nve vni`)
- BGP EVPN now has Type-5 routes (IP prefix advertisements)
- Wireshark shows VNI 50001 on inter-subnet traffic

## What to break

See [`labs/04-anycast-gw/break-it.md`](../labs/04-anycast-gw/break-it.md).
Highlights:

- Mismatched anycast MAC on the two leaves (silent ARP confusion)
- Missing `advertise-pip` (Type-5 routes work, but with wrong next-hop)
- Symmetric IRB break (deliberately misconfigure L3VNI mapping)

## What you should be able to explain

1. What's an anycast gateway and what problem does it solve?
2. What is the "distributed gateway MAC" and why is it the same on
   every leaf?
3. What's the difference between an L2VNI and an L3VNI?
4. Walk me through the path of a packet from host1 (VLAN 10) to host2
   (VLAN 20) including encap/decap stages.
5. Why is symmetric IRB called "symmetric"?
6. What is ARP suppression, and how does the leaf know enough to
   suppress?

## Next

**Session 5**: Add a second VRF (Tenant-B), demonstrate that tenants
in different VRFs cannot reach each other across the fabric, then
introduce route leaking for the case where they need to.
