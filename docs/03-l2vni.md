# Session 3: The First L2VNI

**Prerequisites**: Sessions 1 and 2 complete. OSPF underlay healthy, BGP
EVPN sessions Established with PfxRcd=0 on every peer.

**Goal**: Stretch one VLAN across two leaves using a VXLAN tunnel, and
ping between two hosts that think they're on the same L2 segment but
are actually 5+ hops apart through the fabric.

**Lab folder**: [`labs/03-l2vni`](../labs/03-l2vni/)

**Estimated time**: 50 minutes. This is the longest session so far
because there are several new concepts and you'll spend real time on
the verification (which is genuinely fun this session).

---

## Mental model

Sessions 1-2 paved roads and hired a postman. Session 3 is when the
**first letter gets written**.

Picture it this way: host1 is in Singapore. host2 is in Tokyo. They
both believe they're on the same Ethernet segment (subnet 10.100.10.0/24,
"the office LAN"). When host1 ARPs for host2's IP, its broadcast hits
leaf1. Leaf1 thinks: "I need to deliver this to wherever host2 is."

What follows:
1. leaf1 wraps host1's Ethernet frame in a UDP-VXLAN packet
2. The outer packet is sent to leaf2's VTEP IP (10.0.1.22)
3. The underlay routes it leaf1 -> spine -> leaf2 like any other IP packet
4. leaf2 unwraps it and delivers the original Ethernet frame to host2
5. host2 replies; the reverse happens

But for any of this to work, **leaf1 needs to know in advance that
host2's MAC lives behind leaf2's VTEP**. That's BGP-EVPN's job:
distribute MAC location info between leaves *before* traffic flows.

The "letter" we're writing in this session is the **Type-2 EVPN route**:
"VTEP 10.0.1.21 has MAC aaaa.bbbb.cccc reachable via L2VNI 10010."

Every host that comes online sends its MAC and IP via Type-2 routes.
Every leaf in the fabric learns the same thing. That's how you stretch
L2 over an L3 fabric without any flooding.

> **Key insight**: VXLAN-EVPN is "L2 over L3 with a control plane."
> The L3 is the underlay (IP routing). The L2 is what the hosts see
> (Ethernet, same subnet). The control plane (BGP-EVPN) is what makes
> it work without flooding.

---

## What's an L2VNI?

A **VNI** is a "VXLAN Network Identifier" — a 24-bit number (1 to ~16M)
that tags a particular virtual network. It's analogous to a VLAN ID,
but with a much bigger namespace.

Two flavors:
- **L2VNI**: maps a local VLAN to a fabric-wide virtual network.
  Tenants stay in one broadcast domain. Used to stretch L2 across the
  fabric. **This session.**
- **L3VNI**: used for routing between VRFs across the fabric. Session 5.

Mapping convention from `common/ipplan.md`:
- VLAN 10 (local to each leaf) maps to L2VNI 10010 (fabric-wide)

When host1 sends a frame on VLAN 10 to leaf1, leaf1 looks up VLAN 10's
VNI mapping (10010), and encapsulates the frame in a VXLAN header
carrying VNI 10010. At leaf2, the VNI tag tells leaf2 which local VLAN
to deliver the unwrapped frame to (back to VLAN 10).

> **Why VLAN IDs stay local**: VLAN 10 on leaf1 doesn't have to be VLAN
> 10 on leaf2 — they only need to map to the same VNI. In practice
> people keep them matching because it's confusing otherwise, but the
> mechanism doesn't require it.

## Design decisions in this session

### Decision 1: BGP-based ingress replication, not multicast

VXLAN needs to handle **BUM traffic** — Broadcast, Unknown unicast,
Multicast. When host1 ARPs for an unknown MAC, that ARP has to reach
every VTEP that might have the target.

Two approaches:
- **Multicast underlay**: use IP multicast (PIM) so one packet from
  leaf1 reaches all leaves. Efficient, but requires running PIM
  everywhere — extra complexity, harder to troubleshoot.
- **Ingress replication (IR)**: leaf1 sends a unicast copy of the BUM
  packet to *each* known remote VTEP. BGP-EVPN distributes the list of
  remote VTEPs via Type-3 routes. Simple, no multicast required.

We use **ingress replication with BGP** — the standard modern choice
and what the curriculum's intro promised ("no flood and learn, BGP
replication").

You'll see Type-3 EVPN routes appear in this session — those are the
"hi, I'm a VTEP, here's my IP" messages each leaf sends so others know
to replicate BUM traffic to them.

### Decision 2: RD and RT are required, here's why

Every L2VNI on every leaf needs two attributes attached:

- **Route Distinguisher (RD)**: makes routes unique across the fabric.
  Two leaves might both have a host at MAC `aaaa.bbbb.cccc` in VLAN 10
  (rare but possible). Without an RD, BGP can't tell them apart. With
  an RD, each leaf prefixes its routes with its own identifier.
  Format: `loopback0-IP:VNI` (e.g., `10.0.0.21:10010`).
- **Route Target (RT)**: controls which VRFs/VNIs *import* this route.
  Two leaves can have the same RT on their L2VNI 10010 configs, which
  means "share routes with each other." Format: `ASN:VNI` (e.g.,
  `65000:10010`).

Cisco gives us a convenient shortcut: `rd auto` and `route-target
both auto`. The device generates the RD from its own router-id and
the VNI, and uses a deterministic RT format. We'll use these to keep
configs short.

> **Why "both auto"**: RTs can be configured separately for
> import/export, but for symmetric L2VNI we want the same RT both
> directions. `both auto` does that.

### Decision 3: NVE interface sourced from loopback1

`interface nve1` is the logical interface that represents this leaf's
VXLAN tunnel endpoint. Its source IP is what other VTEPs see as the
"address of this VTEP."

We sourced loopback1 (10.0.1.21 on leaf1, 10.0.1.22 on leaf2) all the
way back in Session 1 specifically for this. By keeping VTEP source on
its own loopback (separate from loopback0 used for BGP), you can do
clever things later — like having multiple leaves share a VTEP IP for
vPC (Session 6).

### Decision 4: `host-reachability protocol bgp`

Under `interface nve1`, this single command tells NX-OS: "Don't learn
MACs from flooded traffic. Trust BGP-EVPN as the source of truth for
which MACs are where."

Without this line, the leaf would still learn MACs from received
traffic and *also* learn from BGP, which can lead to conflicts. With
it, BGP wins — which is the whole point of running BGP-EVPN.

This is the line that makes Session 3 "no flood-and-learn." If you
ever wonder how to verify a fabric is using BGP for MAC learning,
search for this line in the config.

## What you'll build (config summary)

On each leaf:
1. Enable the missing features: `feature interface-vlan`,
   `feature vn-segment-vlan-based`
2. Create VLAN 10 with VN-segment 10010
3. Create `interface nve1` sourcing loopback1, with VNI 10010 in
   ingress-replication mode
4. Configure `evpn` block with `vni 10010 l2`, `rd auto`, `route-target
   both auto`
5. Convert Ethernet1/3 to access port in VLAN 10 and unshut it

On hosts:
- After deploy, attach to each host and configure an IP in
  10.100.10.0/24 on its eth1 interface

Spines need **no changes** — they just route IP through the underlay
and reflect BGP routes. They never decapsulate VXLAN. That's the
elegance of spine-leaf: spines have the same config no matter how many
VNIs the fabric has.

## Deploying

```bash
# If Session 2 lab is running, destroy it first
containerlab destroy -t labs/02-overlay/topology.clab.yml --cleanup

# Deploy Session 3
./scripts/deploy.sh 03-l2vni
```

Wait the usual 15-25 minutes.

## Configuring the hosts (manual, this session)

After the lab is healthy, the four NX-OS nodes have their configs but
**host1 and host2 are running alpine with no IPs yet**.

Attach to host1:

```bash
docker exec -it clab-vxlan-evpn-host1 sh
```

Inside the container:

```sh
ip addr add 10.100.10.10/24 dev eth1
ip link set eth1 up
ip addr show eth1
exit
```

The `eth1` is the interface containerlab created when wiring this host
to leaf1's eth3. The `exit` returns you to the VM shell.

Same for host2 with `10.100.10.11/24`:

```bash
docker exec -it clab-vxlan-evpn-host2 sh
```

```sh
ip addr add 10.100.10.11/24 dev eth1
ip link set eth1 up
exit
```

> **Why manual**: a teaching choice. You see exactly what's needed to
> bring a host onto the L2 segment. In a refactor session we'll add
> `exec:` blocks to the topology.clab.yml so this auto-runs on deploy.
> For now, do it by hand.

## The moment of truth

From host1:

```sh
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11
```

If everything is right, you'll see three replies. Those packets just
traveled host1 -> leaf1 -> [VXLAN encap] -> spine -> leaf2 -> [VXLAN
decap] -> host2 -> reverse path. The hosts have no idea any of this
happened — they think they're on the same LAN.

If the ping fails, work through the verify checklist methodically.
Type-2 routes flowing in BGP, the NVE peer relationship being
"complete", and the VLAN-to-VNI mapping being right are the most
common things to recheck.

## What to verify

See [`labs/03-l2vni/verify.md`](../labs/03-l2vni/verify.md). New
commands for this session:

- `show bgp l2vpn evpn` (the route table itself)
- `show l2route evpn mac all`
- `show nve peers`
- `show nve vni`
- `show mac address-table dynamic`

## What to break

See [`labs/03-l2vni/break-it.md`](../labs/03-l2vni/break-it.md).
Highlights:

- Remove `host-reachability protocol bgp` and watch the fabric fall
  back to flood-and-learn behavior (educational comparison)
- Configure mismatched VNIs on the two leaves and watch ping fail in
  the most confusing way possible
- Bring an extra host MAC onto leaf1 and watch the EVPN Type-2 route
  for it appear in real time

## What you should be able to explain after this session

1. What is an L2VNI and how does VLAN-to-VNI mapping work?
2. What is a Type-2 EVPN route and what does it contain?
3. What is a Type-3 EVPN route and why is it needed?
4. What is ingress replication and why did we pick it over multicast?
5. What does `host-reachability protocol bgp` actually do?
6. Why don't the spines need any config changes in this session?
7. When host1 pings host2, trace the packet's full path including
   encapsulation/decapsulation steps.

## Next

**Session 4**: Anycast gateway with symmetric IRB. We give VLAN 10 a
first-hop gateway IP that exists on every leaf simultaneously — so a
host's default gateway is on its local leaf, not at some distant
router. This is the feature that lets hosts move between leaves without
re-ARPing.
