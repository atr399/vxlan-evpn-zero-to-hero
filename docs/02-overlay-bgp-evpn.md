# Session 2: Overlay with BGP EVPN

**Prerequisites**: Session 1 complete. OSPF underlay up, all loopbacks
reachable, including the VTEP loopbacks (10.0.1.21 and 10.0.1.22).

**Goal**: Build the BGP-EVPN control plane on top of the underlay. By
the end, every leaf has iBGP sessions to both spines, the spines act as
route reflectors, and the `l2vpn evpn` address-family is up and ready
to carry routes (even though there are no routes yet).

**Lab folder**: [`labs/02-overlay`](../labs/02-overlay/)

**Estimated time**: 40 minutes including verification and break-it
exercises.

---

## Mental model

Session 1 was the highway system. Session 2 is the **postal service**
that drives on those highways.

Picture it this way:
- **OSPF** built the roads. Every leaf can reach every other leaf's
  loopback.
- **BGP-EVPN** is a mail truck. It drives from leaf to leaf using those
  roads, carrying envelopes that say things like *"I have host
  10.100.10.10 with MAC aaaa.bbbb.cccc behind me"*.
- **Spines aren't the postman** — they're **sorting offices** (route
  reflectors). A leaf gives one envelope to the spine, and the spine
  copies that envelope to every other leaf. The leaves never need to
  talk to each other directly.

In this session we hire the postman, give him a uniform, and tell him
where the sorting offices are. He's ready to deliver mail, but **no
mail has been written yet**. That comes in Session 3, when we enable
the first L2VNI and hosts start advertising their MAC addresses.

> **Why this matters**: separating "build the postal service" from
> "send the first letter" is a deliberate teaching choice. In
> production you bring BGP-EVPN up *before* enabling any VXLAN, then
> turn on VXLAN services on top. Mixing the two makes troubleshooting
> miserable. We're learning the right order.

---

## Why we need a second control plane at all

This is the question that confuses people first encountering VXLAN-EVPN:
"Wait, we have OSPF already. Why do we need BGP too?"

Because the two protocols carry **different information** at **different
scopes**:

| Protocol  | Information it carries                       | Scope                            |
|-----------|----------------------------------------------|----------------------------------|
| OSPF      | Loopback and link IPs of the leaves/spines   | Underlay only (physical network) |
| BGP EVPN  | Tenant MAC addresses, IP addresses, VRFs     | Overlay only (virtual network)   |

OSPF answers: *"How do I send an IP packet to leaf2's VTEP?"*
BGP-EVPN answers: *"Which leaf is host 10.100.10.10 behind? What's its MAC?"*

You need both. OSPF for the physical reachability, BGP-EVPN for the
tenant lookup. Without OSPF the BGP sessions can't even come up
(because BGP rides on top of IP). Without BGP-EVPN, leaves wouldn't
know where to send tunneled traffic.

## Why BGP for the overlay (not OSPF, not LISP, not something else)

When VXLAN was first standardized (RFC 7348), it used **flood-and-learn**:
no control plane at all, MACs were learned by flooding multicast through
the fabric. It worked but had scaling problems — every BUM (Broadcast,
Unknown unicast, Multicast) packet was replicated to every VTEP, and
MAC tables grew uncontrolled.

The industry solution was to add a control plane that distributes
MAC/IP info ahead of time, so you don't need flood-and-learn. The
choice landed on **BGP with the EVPN address family** because:

1. **BGP already scales.** The internet runs on BGP. If it can carry
   1M+ routes between continents, it can carry MAC addresses in a data
   center.
2. **BGP supports multiple address families** in one session. The same
   neighbor relationship can carry IPv4 routes, IPv6 routes, VPNv4
   routes, and EVPN routes. Modern VXLAN deployments lean on this.
3. **BGP has policy controls** (route-maps, communities) that work
   uniformly across address families. You can filter tenant routes the
   same way you filter internet routes.
4. **Vendor support is universal.** Every serious DC switch vendor
   supports BGP-EVPN. It's the de facto standard now (RFC 7432, 8365).

We'll discuss flood-and-learn briefly in the appendix session — it's
worth understanding for historical context and for legacy environments,
but production deployments use BGP-EVPN today.

## Why iBGP, not eBGP, for the overlay

We have a fundamental decision: do leaves and spines run iBGP (single
AS) or eBGP (different ASes per device)?

For the **overlay** in a single fabric, **iBGP is the standard choice**:

- All leaves and spines join one logical AS (we use AS 65000).
- The fabric is one administrative domain — there's no reason for
  internal devices to look like separate autonomous systems.
- iBGP cleanly preserves BGP attributes (next-hop, community, etc.)
  across the fabric without needing complex policy.

eBGP-EVPN exists and works (some hyperscalers use it), but it adds
configuration complexity (route-target rewriting, next-hop manipulation)
without enough payoff at small/medium fabric scale.

For the **underlay** in Session 7 we will switch from OSPF to *eBGP per
device* — but that's a different protocol instance for a different
purpose (carrying loopback reachability across the physical network).
Don't confuse the two.

## The route-reflector pattern

iBGP has a rule: **iBGP-learned routes are not re-advertised to other
iBGP peers.** This prevents routing loops in classic ISP designs.

It also means: if leaf1 sends a route to spine1, spine1 won't forward
that route to leaf2. So how do leaves learn each other's routes?

Two options:

1. **Full mesh**: every leaf peers with every other leaf directly. With
   4 leaves that's 6 sessions (4*3/2). With 64 leaves that's 2,016
   sessions. Doesn't scale.
2. **Route reflectors**: designate certain devices as RRs that **are**
   allowed to forward iBGP routes. Leaves only peer with the RRs.

In spine-leaf, **the spines naturally fit the RR role**. They already
have sessions to every leaf for the underlay. So we make spines the
RRs and leaves the RR clients.

Result: each leaf has 2 BGP sessions (one to each spine), not N-1
sessions to every other leaf. Adding a new leaf is trivial — just
configure 2 sessions on the new leaf and 1 session on each spine.

> **Mental check**: with 50 leaves and 2 spines, how many BGP sessions
> total in the fabric? Answer: 50 × 2 = 100. With full mesh it would be
> 50 × 49 / 2 = 1,225. That's the win.

## Design decisions in the overlay config

### Decision 1: BGP source from Loopback0, not from physical interface

When a BGP session comes up between two devices, each end uses a
specific IP as its source. Two options:

- **Physical interface IP** — fragile. If the link goes down, the BGP
  session dies even if there's another path available.
- **Loopback IP** — robust. Loopback never goes down (it's a logical
  interface). As long as *any* path exists between the two loopbacks
  in the underlay, the BGP session stays up.

We use `update-source loopback0` so the BGP session survives any
single link failure in the underlay. This is the same trick we use
for IGP-stable iBGP everywhere — not VXLAN-specific.

### Decision 2: `next-hop-self` on the route reflectors

By default, when a route reflector forwards a route, it preserves the
original next-hop (the originating leaf's VTEP IP). For our underlay
that's actually fine — every leaf can reach every other leaf's VTEP IP
via OSPF, so the next-hop resolves.

**But** we configure `route-reflector-client` on the spines without
`next-hop-self` deliberately: we **want** the leaf-to-leaf VTEP next-hop
preserved through the spine. The data plane (VXLAN traffic) goes
**directly leaf-to-leaf**, not via the spine — the spine only sees the
encapsulated IP packet and forwards it like any other UDP. If the
next-hop were rewritten to the spine, VXLAN traffic would try to
terminate on the spine, which has no NVE.

This is a critical distinction:
- **Control plane** (BGP) goes leaf → spine → leaf
- **Data plane** (VXLAN UDP) goes leaf → spine → leaf, but the spine
  just IP-routes it; it never decapsulates

> **Cisco trap**: NX-OS has `next-hop-self all` and `next-hop-self`
> (default behavior). For VXLAN-EVPN do **not** set `next-hop-self` on
> RRs. Preserve the original VTEP as next-hop.

### Decision 3: `address-family l2vpn evpn` everywhere

iBGP supports multiple address families. The classic one is `ipv4
unicast` (regular IP routes). For VXLAN we activate the `l2vpn evpn`
address family on every session.

A single BGP session between, say, leaf1 and spine1 carries:
- (Eventually) `ipv4 unicast` routes from the underlay's perspective —
  but in our design OSPF handles that, so this AF stays empty
- `l2vpn evpn` routes — this is where MAC/IP advertisements live

In session 2 we activate `l2vpn evpn` but no routes flow yet because
there are no VNIs. In session 3 the first Type-2 routes (MAC/IP
advertisements) will appear.

### Decision 4: BGP timers — accept defaults for now

NX-OS defaults: keepalive 60s, holdtime 180s. That means a dead BGP
peer is detected in up to 3 minutes — slow.

In production you'd tune these (or better, enable **BFD** for
sub-second detection). We accept the defaults in session 2 to keep
things simple. We'll tune timers + add BFD in session 7 when we
refactor for production-grade convergence.

## What's NOT in this session

To keep the cognitive load manageable, session 2 deliberately stops at
"BGP sessions up, ready to carry routes." Specifically **not yet**:

- ❌ VLANs and L2VNIs (session 3)
- ❌ NVE / VXLAN tunnels (session 3)
- ❌ Anycast gateway / SVIs (session 4)
- ❌ VRFs and L3VNIs (session 5)
- ❌ vPC for dual-homed hosts (session 6)

You **will** see this output at the end of session 2:

```
spine1# show bgp l2vpn evpn summary
...
Neighbor        V    AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down State/PfxRcd
10.0.0.21       4 65000      8       8        1    0    0 00:02:14 0
10.0.0.22       4 65000      7       7        1    0    0 00:02:01 0
```

Notice the `0` in the `PfxRcd` column — sessions are up but no
EVPN prefixes are being exchanged yet. That's correct for this
session. Session 3 will fill that in.

## Deploying

```bash
./scripts/deploy.sh 02-overlay
```

What happens:

1. If a Session 1 lab is still running, you should destroy it first:
   ```bash
   containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup
   ```
2. Containerlab deploys the same 4 NX-OS + 2 hosts topology, but with
   the Session 2 configs which include both underlay (OSPF) AND
   overlay (BGP) config.
3. ~15-25 minute boot for the four n9kv nodes.

## What to verify

See [`labs/02-overlay/verify.md`](../labs/02-overlay/verify.md). The
key checks:

1. OSPF still works (we didn't break the underlay).
2. All 4 BGP sessions are Established (2 per leaf × 2 leaves).
3. `l2vpn evpn` AF is active on all sessions.
4. PfxRcd is 0 on all sessions (correct — no VNIs yet).

## What to break

See [`labs/02-overlay/break-it.md`](../labs/02-overlay/break-it.md).
Highlights:

- Kill BGP on spine1 — watch leaves keep BGP up via spine2 (RR
  redundancy).
- Remove `update-source loopback0` on one side — watch the session
  never establish.
- Shut the physical link between leaf1 and spine1 — watch BGP stay up
  through spine2 even though the direct path is gone (because BGP
  rides on the loopback, which is still reachable via spine2).

## What you should be able to explain after this session

1. Why does VXLAN need a control plane on top of the underlay?
2. Why iBGP and not eBGP for the overlay (within a single fabric)?
3. What is a route reflector and why are the spines natural RRs in a
   spine-leaf design?
4. Why do we source BGP from loopback0 instead of a physical interface?
5. Why should we *not* set `next-hop-self` on the spine RRs?
6. What's the difference between control plane and data plane in a
   VXLAN-EVPN fabric?

If you can answer all six, you're ready for session 3 where things get
visibly exciting (host-to-host ping over VXLAN).

## Next

**Session 3**: First L2VNI. We bring up VLAN 10 on both leaves, map it
to VNI 10010, enable NVE on the leaves with ingress replication, and
connect host1 and host2 to that VLAN. After session 3 you'll see
Type-2 EVPN routes being exchanged and ping between host1 and host2
working over a VXLAN tunnel.
