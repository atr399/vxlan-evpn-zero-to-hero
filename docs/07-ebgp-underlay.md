# Session 7: eBGP Underlay + eBGP-EVPN Overlay (RFC 7938)

**Prerequisites**: Session 6c working. Cross-tenant ping over LACP
bond with shared VTEP.

**Goal**: Refactor the underlay from OSPF (link-state IGP) to eBGP
(per-device unique ASN). This is the design that hyperscalers
(Microsoft, Meta, Cloudflare) use because eBGP scales better than
OSPF at thousands of devices. The overlay also becomes eBGP-EVPN
(no more route reflectors) because spines no longer share the
overlay ASN with leaves.

**Lab folder**: `labs/07-ebgp-underlay/`

**Estimated time**: 40-45 minutes

**No topology change**: pure config refactor. Same physical wires.

---

## Bring-up

Pure config refactor on the running lab (Model A) — no topology change,
no host changes:

```bash
cd ~/vxlan-evpn-zero-to-hero
./scripts/switch.sh 07-ebgp-underlay
# The push includes deletions (no router ospf / no router bgp 65000)
# followed by the new per-device-ASN BGP config.
```

**Expect a ~30–60 s window of partial reachability** during the
protocol swap (OSPF removed → eBGP forms → EVPN re-converges). Don't
debug inside that window — wait, then run the tests below.

---

## Mental model

OSPF was easy to understand:
- One area, one process, one ASN
- Devices flood LSAs to each other, build a complete view of
  the topology
- Routes computed via SPF

But OSPF doesn't scale well past ~50 devices. Why? LSA flooding
becomes expensive. Every link state change ripples everywhere.
And OSPF doesn't have BGP's policy expressiveness (route filters,
prefix lists, communities, RPKI).

**eBGP** as underlay solves both:
- Each device has its own ASN
- Each spine-leaf link is an eBGP session
- Loop prevention is automatic (BGP drops routes containing its
  own ASN in the AS-path)
- Scales to tens of thousands of devices

**RFC 7938** is the IETF document that codified the hyperscale
eBGP-underlay pattern. Microsoft adopted it for Azure. Meta uses
it for its data centers. It's now the standard for new builds.

---

## The architecture

```
              spine1 (AS 65001)   spine2 (AS 65002)
                  \\              //
                   \\            //
                    \\          //
                  leaf1 (AS 65011)  leaf2 (AS 65011)
                  [vPC pair share ASN]
```

| Device | ASN | Role |
|--------|-----|------|
| spine1 | 65001 | eBGP to all leaves; propagates EVPN |
| spine2 | 65002 | Same as spine1 |
| leaf1  | 65011 | eBGP to both spines; vPC primary |
| leaf2  | 65011 | Same ASN as leaf1 (vPC pair sharing) |

**Why leaves share an ASN**: vPC pairs are logically one switch.
They must be in the same BGP entity. If they had different ASNs,
the peer-link would carry "eBGP between AS 65011 and 65012" which
doesn't make architectural sense.

**Consequence of shared leaf ASN**: when leaf1 advertises a route
to spine1 (eBGP), spine1 propagates it to leaf2 (eBGP). leaf2
sees its own ASN in the path → BGP loop prevention drops it.
Fix: `allowas-in 1` on the leaves' EVPN neighbor config.

This is the central trade-off of the design — RFC 7938 wants per-
device ASN, vPC wants shared ASN. We get both by using shared
ASN within the vPC pair only, plus `allowas-in`.

---

## What changes vs Session 6

| Component | Session 6 (OSPF + iBGP-EVPN) | Session 7 (eBGP everywhere) |
|-----------|-------------------------------|------------------------------|
| Underlay protocol | OSPF area 0 | eBGP per-device |
| Underlay ASN model | Single AS 65000 | spine1=65001, spine2=65002, leaves=65011 |
| Overlay protocol | iBGP-EVPN with RR | eBGP-EVPN |
| Spine role | Route reflector | Just propagates eBGP normally |
| EVPN neighbor | Loopback-sourced (iBGP) | Directly-connected (eBGP) |
| RT format | `auto` (derived from AS) | Explicit `65000:VNI` |
| Loop prevention | N/A (iBGP doesn't need) | `allowas-in 1` on vPC leaves |
| Spine extra config | None | `rewrite-evpn-rt-asn` |

The RT format change is subtle but critical. With `auto`, the RT
is `<local-AS>:<VNI>`. If leaf1 (AS 65011) advertises VNI 10010,
RT is `65011:10010`. leaf2 expects to import `65011:10010` (its
own local AS) but receives `65011:10010` — mismatch. To make it
work uniformly we hardcode RTs to `65000:VNI` everywhere.

---

## The bigger picture

This refactor is what real enterprises do when they grow their
data center beyond ~50 leaves. The OSPF design was simpler but
hit scale limits. The eBGP design is more complex but scales to
hyperscale.

For your 4-node lab, both designs work fine. The teaching value
is seeing the architectural shift — same topology, completely
different routing protocol model, same data plane outcome.

---

## What you'll do

```bash
cd ~/vxlan-evpn-zero-to-hero
./scripts/switch.sh 07-ebgp-underlay
```

The cfg push includes **deletions** for the first time:
- `no router ospf UNDERLAY` removes the OSPF process
- `no router bgp 65000` removes the old iBGP-EVPN process

Then it adds the new per-device-ASN BGP processes with
ipv4-unicast (underlay) and l2vpn-evpn (overlay) under the same
`router bgp <local-asn>` block.

**Expect a ~30-60 second window of partial reachability** during
the protocol swap. OSPF goes away → loopback reachability
temporarily lost → eBGP forms → reachability returns → EVPN
re-converges. Don't panic if ping fails during this window.

---

## Key tests

### Test 1: Underlay reachability via eBGP

```
show ip route 10.0.0.22
```

Should show 2 paths (ECMP via both spines), each labeled `bgp-65011,
external` (eBGP).

### Test 2: Both planes Established

```
show bgp ipv4 unicast summary
show bgp l2vpn evpn summary
```

Both should show 2 neighbors in Established state.

### Test 3: Cross-tenant ping still works

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Same outcome as Session 6: TTL=62 or 63, low loss.

### Test 4: vPC unchanged

```
show vpc
```

vPC operates the same as before. The underlay/overlay refactor
doesn't affect vPC — it's protocol-independent.

---

## Production patterns we're foreshadowing

**BFD on eBGP sessions**: With default BGP timers (hold timer 180s),
spine failure takes ~3 minutes to detect. Production fabrics layer
BFD on top of eBGP for sub-second failure detection. We didn't add
BFD in this session — too much new at once. A separate session
will add it.

**ECMP at scale**: Real hyperscale fabrics use `maximum-paths 64`
to use all 64+ spines. Our `maximum-paths 2` is for the 2-spine lab.
The concept is identical — eBGP installs all equal-cost paths.

**Per-pod ASNs in multi-pod**: When fabrics grow beyond a single
spine layer, RFC 7938 recommends per-POD super-spine architectures
with different ASN ranges per pod. We'll see this in Session 10
(Multi-Pod).

**ASN exhaustion**: At 50,000+ devices, even 16-bit ASNs (1-65535)
become limiting. Hyperscalers use **4-byte ASNs** (RFC 6793) for
addressing. Same protocol mechanics, just bigger numbers.

---

## What you should be able to explain after Session 7

1. Why hyperscalers use eBGP underlay instead of OSPF
2. What `rewrite-evpn-rt-asn` does and why spines need it
3. Why vPC pairs share an ASN in an otherwise per-device-ASN fabric
4. What `allowas-in` solves and when it's needed
5. The trade-off between automatic and explicit BGP route-targets

---

## What's next

Session 8: L2Out — extending an L2VNI out to an external switch
(non-fabric device). Common need: legacy gear in the same VLAN
as fabric-attached hosts. Adds external connectivity to the L2
plane.

Session 9: L3Out — extending tenant VRFs out to an external
router. The pattern for "fabric to WAN" connectivity.

After 8 and 9, we'll have all the production-essential building
blocks. Sessions 10-11 (multi-pod, multi-site) are scaling
patterns for multi-fabric deployments.
