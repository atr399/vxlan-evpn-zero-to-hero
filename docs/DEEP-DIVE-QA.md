# EVPN Deep-Dive Q&A — Study Companion

Question-and-answer format for review and interview prep. Sourced from
cross-AI study discussions, **audited against Cisco docs and this lab's
verified behavior**. Tags: ✅ verified live on this lab · 📖 correct per
documentation · ⚠️ nuance/caution — read the note.

Each answer has three layers: **the short answer** (say this in an
interview), **the why** (understand it), **prove it** (the lab command).

---

## Part 1 — Integrated Routing and Bridging (IRB)

**Q: Asymmetric vs Symmetric IRB — the fundamental difference?** ✅

*Short:* Asymmetric = ingress leaf does ALL the work (route + bridge into
the destination VLAN before tunneling). Symmetric = the work is split;
ingress routes INTO a shared transit VNI (L3VNI), egress routes OUT.

*Why it matters:* asymmetric forces **every leaf to carry every VLAN**
— if leaf1 must bridge into VLAN 20 before tunneling, leaf1 needs VLAN
20 configured even with zero local VLAN-20 hosts. At 500 VLANs × 100
leaves, that's a MAC-table and config explosion. Symmetric IRB's whole
win: a leaf only carries VLANs for hosts physically attached to it;
everything remote goes via the one L3VNI per tenant.

*Prove it:* your leaf1 has no VLAN 20 in Session 4, yet host1 reaches
10.100.20.10. `show vlan brief` on leaf1 vs the working ping IS the
proof.

**Q: How does the silicon decide bridge vs route?** ✅

*Short:* by the frame's **destination MAC**. A host's MAC → bridge
(L2VNI). The switch's own gateway/router MAC → strip L2, route (L3VNI).

*Why:* this is ordinary router behavior — a router only routes frames
addressed TO it at L2. The anycast gateway makes every leaf "the
router" for every local subnet, so hosts always hand frames to the
leaf's MAC when leaving their subnet.

*Prove it:* Session 3's ping arrives TTL 64 (bridged, MAC = host2's);
Session 4's arrives TTL 62 (routed twice, MAC was the gateway's).

**Q: What MACs sit in the inner Ethernet header on the L3VNI?** ✅ (the
famous correction)

*Short:* source = **ingress leaf's System Router MAC**, destination =
**egress leaf's System Router MAC**. NOT the hosts' MACs, and NOT the
anycast gateway MAC.

*Why:* once the ingress leaf routes, it rewrites L2 toward the next hop
— and the next hop is the egress leaf's routing engine. It learns that
leaf's router MAC from the **Router-MAC extended community** on the BGP
route. The anycast MAC exists only on the host↔leaf hop.

*Prove it:* `show bgp l2vpn evpn <host-ip>` on leaf1 → find `Router
MAC:` in the communities; compare with `show nve interface nve1 detail |
include Router` on leaf2 — they match, and a two-uplink capture shows
those two MACs inside the tunnel. (This doc's history: an earlier draft
said "anycast MAC inside" — the live capture killed that error. Trust
captures over intuition.)

---

## Part 2 — Route Types & VNIs

**Q: L2VNI vs L3VNI?** ✅

*Short:* L2VNI = a VLAN's bridging domain stretched across the fabric
(1:1 with VLAN). L3VNI = a VRF's routing highway (1:1 with tenant).

*Why the split:* bridged same-subnet traffic must preserve host MACs
end-to-end (L2VNI). Routed traffic has no fixed VLAN at ingress — it
needs a VLAN-agnostic transit that only identifies the TENANT, so the
egress leaf knows which routing table (VRF) to use. The L3VNI number IS
the VRF context on the wire.

**Q: The three forwarding route types?** ✅

*Short:* **Type-2** = host granularity (MAC+IP /32 — "this exact host
lives behind this VTEP"). **Type-3** = the flood list ("I participate
in VNI X — send me BUM"). **Type-5** = subnet granularity ("this /24 is
reachable via me" — the border/external mechanism).

*Why three:* they answer three different questions — where is this
host / who needs my broadcasts / where is this network. Sessions 3, 3,
and 9 respectively make each one load-bearing.

**Q: Why does Type-5 often show Gateway IP 0.0.0.0?** 📖

*Short:* 0.0.0.0 = "the subnet is attached at the advertising VTEP —
just forward to the route's next-hop." A real IP there = recursive
hand-off ("to reach this prefix, first route to THIS address" — e.g. a
firewall behind the border leaf).

*Prove it:* Session 9, `show bgp l2vpn evpn route-type 5` — the external
203.0.113.0/24 carries 0.0.0.0. Session 15's firewall design is exactly
the non-zero-gateway use case done with statics instead.

---

## Part 3 — RD and RT

**Q: RD vs RT, fundamentally?** ✅

*Short:* **RD makes a route unique** (prefix disambiguation so two
tenants' 10.0.0.0/24 don't collide in one BGP table). **RT delivers it**
(which VRF/VLAN imports the route).

*Why both exist:* uniqueness and delivery are different problems. RD is
a dumb prefix — it carries no meaning, it just prevents collisions. RT
is policy — import/export tags deciding who receives what. Mixing them
up is the #1 EVPN interview trap.

**Q: Same L2 RT across different VLANs — what happens?** 📖

*Short:* you fuse their broadcast domains into one stretched bridge
domain (with on-the-fly VLAN translation). Almost always a mistake:
a broadcast storm in one VLAN now takes down both.

*Why it's tempting and wrong:* it LOOKS like an easy way to "merge"
segments. The safe tool for inter-segment connectivity is L3 (routing,
leak, or Session 15's firewall) — never L2 RT merging. Blast radius is
the whole argument.

**Q: Why TWO route-target import lines (with and without `evpn`)?** ⚠️

*Short:* the `evpn` line governs import from the **L2VPN EVPN table**
(routes arriving over the fabric); the plain line governs the
**VPNv4/VPNv6 address families** — per Cisco docs, for MPLS/VRF-Lite
hand-off.

*The nuance (honest):* on this lab, removing the plain line breaks even
the pure-fabric leak — because the local inter-VRF leak on the same box
processes through the VPN table machinery. So functionally: **both
lines are required; a route must clear both table boundaries.** The
half-configured signature: route visible in `show bgp l2vpn evpn` but
absent from `show ip route vrf X`.

*Prove it:* the Session 5 break-it — remove ONE import line, watch the
route survive in the EVPN table and die in the VRF, ping dies, re-add,
recovery. (Designed; run it to settle the mechanism empirically.)

---

## Part 4 — Spines and vPC

**Q: The spine's exact role?** ✅

*Short:* data plane — a dumb outer-IP relay (never decapsulates, can't
even see the VNI). Control plane — the BGP Route Reflector.

*Prove it:* `show nve peers` on a spine = EMPTY, while `show bgp l2vpn
evpn summary` shows every leaf. It reflects routes it can never use.
(Exception by design: Session 11's collapsed spine+BGW.)

**Q: How does vPC prevent routing loops between the peers?** ✅

*Short:* **Site-of-Origin (SOO)**. Routes the pair advertises carry an
SOO tag and next-hop = the shared VIP; a peer receiving a route stamped
with its own SOO drops it (BGP split-horizon).

*Why elegant:* the loop prevention is pure control-plane — no data-plane
hack, no special tunnel. *Prove it:* `show bgp l2vpn evpn 10.100.10.10 |
grep -i soo` after Session 6c.

---

## Part 5 — Decoding BGP EVPN Output

**Q: Reading `[2]:[0]:[0]:[48]:[aac1.ab5e.c305]:[32]:[10.100.10.10]/272`?** ✅

*Short:* type-2 : reserved : reserved : MAC-length(48) : the MAC :
IP-length(32) : the IP. A MAC-only route shows `[0]:[0.0.0.0]` — MAC
learned, no ARP yet (a silent host at L3).

**Q: `ENCAP:8`?** ✅ — the data-plane instruction: use **VXLAN**
(tunnel-type 8). The route doesn't just say WHERE; it says HOW to get
there.

**Q: "Imported to 5 destination(s)"?** ✅

*Short:* the RT fan-out counter — one received route copied into every
table whose RT matches (its L2VNI, its home VRF, and post-leak, the
OTHER tenant's VRF).

*Prove it:* Session 5 — watch the count RISE the moment 5b's leak is
applied. Route leaking, visible in the control plane before any ping.

**Q: Spotting the Router MAC as a standalone Type-2 (MAC-only, L3VNI
label, "Router MAC" flag)?** ⚠️

*Caution:* platform-dependent. On NX-OS the router MAC primarily rides
as the **extended community attached to** Type-2/Type-5 routes — a
standalone RMAC Type-2 may or may not appear in your table. Check
before teaching it: `show bgp l2vpn evpn | include 0.0.0.0`, inspect
candidates for the Router-MAC flag. Most MAC-only Type-2s are silent
hosts, not gateways.

---

## Part 6 — Multipod vs Multisite

**Q: The fundamental architectural difference?** ✅

*Short:* Multi-Pod = ONE fabric, ONE control plane, stretched over an
IPN — one fault domain. Multi-Site = INDEPENDENT fabrics joined by
Border Gateways over a DCI — strict fault isolation.

*The one-field proof (memorize this):* look at a cross-domain route's
**next-hop**. Multi-Pod: the origin leaf's VTEP, **preserved**
end-to-end. Multi-Site: **rewritten** to the remote BGW VIP
(10.0.2.100 on this lab). Preserved = Pod, rewritten = Site — the
entire architecture argument in one routing-table field.

**Q: Verifying cross-pod control plane?** ✅

Underlay first: IPN OSPF neighbors all FULL (this lab: 4×, and the
MTU-9214 bounce is the #1 blocker). Then overlay: **spine-to-spine**
EVPN peering across the IPN (`show bgp l2vpn evpn summary` on a spine —
the remote pod's spine established).

**Q: Tunnel stitching?** ✅

*Short:* the leaf's tunnel terminates at ITS site's BGW; the BGW starts
a brand-new tunnel across the DCI to the remote BGW; that BGW starts a
third leg to its local leaf. Two stitch points — which is why cross-site
RTT jumped to 50–115ms vs 10–18ms cross-pod on this lab, and why the
TTL loses one more (the BGW routes).

**Q: RT numbering across independently-managed sites?** ⚠️

*Short:* sites with different ASNs auto-derive different RTs (ASN:VNI)
— something must reconcile them at the border. The generic answer is RT
translation/mapping on the BGW; **this lab uses `rewrite-evpn-rt-asn`**
on the DCI eBGP peering (verify: `show run bgp | include rewrite` on
spine1) — the ASN portion is rewritten in-flight so auto-RTs match.
Mapping *tables* are the manual alternative when rewrite can't cover a
design.

---

## How to study this

1. Cover the answers, attempt the *Short* line out loud (interview rep).
2. For any ✅, run the *Prove it* command on a live lab — the output is
   the real flashcard.
3. The two ⚠️ items are designed break-its (Session 5's dual-RT test)
   or table-inspections — settle them yourself and upgrade the tag.
