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

## Bring-up

**Recommended (Model A chain)** — push onto the running lab:

```bash
cd ~/vxlan-evpn-zero-to-hero
./scripts/switch.sh 04-anycast-gw
# switch.sh prints the host-setup commands for this session:
# host1 stays in VLAN 10 (gw 10.100.10.1), host2 moves to VLAN 20
# (gw 10.100.20.1), both with 'ip route replace default'. Run those.
```

**Alternative (standalone)**: destroy + `./scripts/deploy.sh
04-anycast-gw`, then the same host setup.

## Topology (this session)

Same physical wiring. What's new: two subnets, an **anycast gateway on
every leaf** (same IP + MAC), VRF Tenant-A, and the **L3VNI** for
routed traffic:

```
   host1 VLAN 10                              host2 VLAN 20
   10.100.10.10/24                            10.100.20.10/24
   gw 10.100.10.1                             gw 10.100.20.1
     |                                              |
   leaf1                                          leaf2
   SVI Vlan10: 10.100.10.1  <- same anycast ->  SVI Vlan10: 10.100.10.1
   SVI Vlan20: 10.100.20.1     IPs + MAC        SVI Vlan20: 10.100.20.1
   (anycast MAC 0000.2222.3333 on both leaves, all SVIs)
     \\                                            //
      ================ L3VNI 50001 =================
        (VRF Tenant-A routed traffic, symmetric IRB:
         both leaves route; TTL drops by 2 end-to-end)
```

Cross-subnet traffic: routed at the ingress leaf into VNI **50001**,
carried across, routed again at egress. Same-subnet traffic still uses
the L2VNI (10010).

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

### Decision 3: SVI with `fabric forwarding mode anycast-gateway`

For each VLAN that needs L3, we create an SVI (`interface Vlan10`).
This SVI:
- Has the gateway IP (10.100.10.1)
- Lives inside the tenant VRF (`vrf member Tenant-A`)
- Has the magic line `fabric forwarding mode anycast-gateway` — this
  enables anycast behavior on the SVI

Without that one line, the SVI would be a regular SVI with regular ARP
behavior. With it, the SVI uses the fabric-wide anycast MAC and
suppresses ARP responses for IPs the EVPN control plane already knows
about.

### Decision 4: Redistribute connected subnets into BGP

This is the one that bit us during initial lab testing — worth its
own section.

For Type-5 EVPN routes (IP prefix advertisements) to flow between
leaves, the connected SVI subnets need to be in **BGP's IPv4 table
for the tenant VRF**. The line `advertise l2vpn evpn` under the VRF's
ipv4 unicast AF converts BGP IPv4 routes to EVPN Type-5 routes, but
**only routes BGP already knows about**.

By default, BGP doesn't automatically pull connected routes from the
RIB. You have to tell it explicitly:

```
route-map ALL_ROUTES permit 10
!
router bgp 65000
  vrf Tenant-A
    address-family ipv4 unicast
      redistribute direct route-map ALL_ROUTES
      advertise l2vpn evpn
```

The route-map with no match clauses matches everything (a "permit-all"
route-map). `redistribute direct` pulls connected routes into BGP, and
then `advertise l2vpn evpn` exports them as Type-5.

Without this, the fabric will look correct (BGP sessions up, L3VNI
defined, anycast gateways alive) but **cross-subnet ping fails
silently** because no leaf advertises a path to the remote subnet.

### Decision 5: The `advertise-pip` knob

When a leaf advertises a Type-5 route, it needs to say "the next-hop
for this prefix is me." With anycast gateway, **every leaf** could
equally be the next-hop. The fabric uses each leaf's **PIP** (Primary
IP — its loopback1) as the next-hop, not the anycast IP.

`advertise-pip` under BGP EVPN tells the leaf to put its own PIP as
next-hop on EVPN Type-5 advertisements. Without it, Type-5 routes
might point at the anycast IP, which isn't unique across the fabric.

### Decision 6: ARP suppression

Anycast gateways enable **ARP suppression**. When a leaf knows (via
EVPN Type-2 routes) the MAC for an IP, and a host ARPs for that IP,
the leaf replies locally instead of flooding the ARP to the fabric.

This is enormous for scale. Without it, every ARP gets flooded to
every leaf in the fabric. With it, ARPs stay local most of the time.

ARP suppression is automatically enabled when you enable anycast
gateway. You just see fewer ARP broadcasts in the wild.

## What you'll build

**Same fabric, additional config on leaves**:

1. Configure the distributed gateway MAC
2. Create a "permit all" route-map for redistribution
3. Create VRF Tenant-A, with an associated L3VNI 50001
4. Map VLAN 20 to L2VNI 10020 (a second VLAN this session)
5. Create SVIs for VLAN 10 and VLAN 20 (both anycast)
6. Create the L3VNI carrier SVI (Vlan99 in the VRF)
7. Add NVE members for VNI 10020 (L2) and VNI 50001 (L3)
8. Configure BGP EVPN with `advertise-pip` plus the VRF redistribution

**Hosts**:
- host1 stays on VLAN 10, gets gateway `10.100.10.1`
- host2 moves to VLAN 20, gets gateway `10.100.20.1`

## Deploying (standalone alternative)

> The recommended path is the `switch.sh` chain — see **Bring-up** at
> the top of this doc. The steps below are the standalone alternative:
> a fresh deploy of this session's own topology.

```bash
containerlab destroy -t labs/03-l2vni/topology.clab.yml --cleanup
./scripts/deploy.sh 04-anycast-gw
```

Usual 15-25 min boot.

## Configuring the hosts

The hosts in this lab have **two** network interfaces: `eth0` is
clab's management bridge (with a default route pointing at clab's
gateway), and `eth1` is the lab interface connected to the leaf.

To make the host send tenant traffic via the leaf, we have to
**replace** the default route, not just add one. Using `ip route add`
silently fails because a default already exists via eth0.

```bash
# host1: VLAN 10, gateway 10.100.10.1
docker exec clab-vxlan-evpn-host1 sh -c "ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.10.1"

# host2: VLAN 20, gateway 10.100.20.1
docker exec clab-vxlan-evpn-host2 sh -c "ip addr add 10.100.20.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.20.1"
```

The `ip route replace` form overwrites any existing default. Verify
with:

```bash
docker exec clab-vxlan-evpn-host1 ip route
```

You should see `default via 10.100.10.1 dev eth1` — not via eth0.

> **Note**: After this change, hosts lose internet access via clab's
> management bridge. That's fine for our lab — we don't need internet
> from inside a tenant subnet. `docker exec` still works because it
> bypasses host routing.

## The moment of truth (with packet capture)

This session has **two** moments of truth.

**First moment**: host1 (VLAN 10) pings its own gateway. Proves anycast
works:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1
```

Should succeed instantly. The reply comes from leaf1 (local leaf) with
anycast MAC `00:00:22:22:33:33`.

**Second moment**: host1 pings host2. Crossing subnets, crossing leaves.

In one VS Code terminal, start a capture on leaf1's uplink:

```bash
./scripts/capture.sh leaf1 eth1 04-anycast-cross-subnet 'udp port 4789'
```

In another terminal:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.20.10
```

If everything works:
- The first packet may be lost (ARP resolution); subsequent ones succeed
- TTL of the replies is 62 (started at 64, decremented by 2 — one
  decrement per leaf doing L3 routing)
- The capture has VXLAN frames with **VNI 50001** (the L3VNI), not
  10010 or 10020. That's symmetric IRB.

## What to verify

See [`labs/04-anycast-gw/verify.md`](../labs/04-anycast-gw/verify.md).

## What to break

See [`labs/04-anycast-gw/break-it.md`](../labs/04-anycast-gw/break-it.md).

## What you should be able to explain

1. What's an anycast gateway and what problem does it solve?
2. What is the "distributed gateway MAC" and why is it the same on
   every leaf?
3. What's the difference between an L2VNI and an L3VNI?
4. Walk me through the path of a packet from host1 (VLAN 10) to host2
   (VLAN 20) including encap/decap stages.
5. Why is symmetric IRB called "symmetric"?
6. What's the role of `redistribute direct` and why is it needed even
   when `advertise l2vpn evpn` is already there?
7. What does `advertise-pip` do?

## Lessons from initial lab testing

When this session was first deployed end-to-end, two real issues
surfaced that the original configs missed. Both are now baked into
the cfg files and docs, but worth knowing about because they're
recurring real-world bugs:

1. **`advertise l2vpn evpn` alone is not enough**. You need
   `redistribute direct route-map ALL_ROUTES` (plus the route-map
   itself) for connected subnets to make it into EVPN as Type-5
   routes. Without it, the fabric looks right but pings fail.

2. **Hosts attached via containerlab have a default route via the
   management bridge**. `ip route add default` silently fails. Use
   `ip route replace default`.

## Next

**Session 5**: Add a second VRF (Tenant-B), demonstrate that tenants
in different VRFs cannot reach each other across the fabric, then
introduce route leaking for the case where they need to.
