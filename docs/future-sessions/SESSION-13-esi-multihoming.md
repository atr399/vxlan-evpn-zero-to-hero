# Session 13 — EVPN ESI Multihoming (vPC-less dual-homing) — ⚠ UNTESTED DESIGN SPEC

**Status: design spec, never run.** Written from Cisco NX-OS 10.x EVPN
multihoming docs. Two open platform risks, checked in step 0 before any
build: (1) whether **N9000v/vrnetlab supports `evpn esi multihoming`** at
all (it's ASIC-adjacent), and (2) feature/license gating on 10.5(5).
If step 0 fails, this becomes a doc-only session (like GPO).

## The idea (and why it earns a session)

Sessions 6–11 dual-home host1 with **vPC** — Cisco's MLAG, which needs a
peer-link, keepalive, consistency checks, and a shared VTEP VIP. The
EVPN-native alternative is **ESI multihoming**: both leaves attach to the
host's bond independently, tag the shared segment with the same
**Ethernet Segment Identifier**, and let BGP EVPN do everything vPC did
in hardware+peer-link — with route types you've already met plus one new
one:

- **Type-4 (Ethernet Segment)**: leaves sharing an ESI discover each
  other and elect a **Designated Forwarder** (DF) for BUM per segment.
- **Type-1 (Ethernet A-D)**: fast withdraw — one route pulls all MACs
  behind a failed segment (mass withdrawal), and enables aliasing
  (remote leaves load-balance to both ESI peers even before per-MAC
  learning).
- **Split-horizon** moves from the vPC peer-link/SOO to the ESI label.

Teaching payoff: the "same problem, control-plane solution" contrast
with Session 6, and the only place Type-1/Type-4 appear in the lab.

## Topology delta (from the 01-underlay base, Model A on a reset base)

None physically — reuse the existing host1 dual-wiring
(leaf1:eth3 + leaf2:eth6). The change is pure config: **remove vPC**,
add ESI.

## Config skeleton (per Cisco 10.x syntax — verify exact CLI in step 0)

```
! both leaves — remove vPC domain, peer-link Po100 reverts to fabric/unused
no vpc domain 10

feature evpn esi multihoming        ! step 0: does N9000v accept this?
evpn esi multihoming

interface port-channel 10
  ethernet-segment 2001
    system-mac 0000.0000.2001      ! same on BOTH leaves = same segment
  switchport mode trunk
  switchport trunk allowed vlan 10
```

Also required: remove the shared VTEP secondary IP (`no ip address
10.0.1.100/32 secondary` on loopback1) — ESI MH advertises each leaf's
own VTEP; the VIP is a vPC construct.
host1 keeps the exact same LACP bond (nothing changes host-side — that
symmetry is itself a teaching point).

## Step 0 — platform gate (run before anything else)

```bash
ssh admin@clab-vxlan-evpn-leaf1 'configure terminal ; feature evpn esi multihoming'
ssh admin@clab-vxlan-evpn-leaf1 'show run | include esi'
```
If the feature is rejected/hidden on N9000v → stop, mark session
doc-only, keep vPC labs as the dual-homing story.

## Verify (what good looks like)

```bash
# Type-4 — both leaves advertise the segment; DF elected:
ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn route-type 4'
ssh admin@clab-vxlan-evpn-leaf1 'show nve ethernet-segment'   # want: DF = one of the two leaves
# Type-1 — A-D routes for the segment:
ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn route-type 1'
# Remote leaf sees host1 reachable via BOTH VTEPs (aliasing):
ssh admin@clab-vxlan-evpn-leaf2 'show l2route evpn mac evi 10 detail'
# Data path:
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.10.1
```

## Break-it ideas

1. **Mismatched ESI** on the two leaves → two independent segments, no
   DF election between them; watch duplicate/dropped BUM behavior.
2. **Kill the DF leaf's host link** → Type-1 mass withdrawal; time how
   fast the remote leaf repoints (compare with vPC failover from S6).
3. Re-add the vPC secondary VIP while ESI is up → observe the conflict.

## Honest caveats

- N9000v may not implement DF filtering in its virtual data plane even
  if the CLI accepts config — BUM tests may behave incorrectly. Verify
  BUM (broadcast ping) explicitly, not just unicast.
- Cisco's production guidance still favors vPC on Nexus; ESI MH is the
  standards-based path (and what Arista/Juniper use by default). Framing
  that vendor split is part of the lesson.
