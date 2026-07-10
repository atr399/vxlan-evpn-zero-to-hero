# Session 15 — Firewall Insertion (VRF Sandwich + PBR Steering)

> **STATUS: UNTESTED DESIGN.** Written post-gate: `feature pbr` verified
> present on N9000v 10.5(5); ePBR and ITD verified **absent** (CLI gate,
> July 2026). Predictions in verify.md are to be confirmed live —
> Session-12 style, where wrong predictions become break-its.

## Mental model

Session 5b's route-leak connected two tenants *conveniently* — and with
zero inspection. This session replaces convenience with **policy**: rip
out the leak, and make the only path between tenants run **through a
firewall**. The fabric's job shifts from "connect everything" to
"connect only via the checkpoint." This is the pattern real enterprises
run (ACI calls it a service graph; NX-OS fabrics do it with routing).

Two insertion models, one lab:
- **Act 1 — VRF sandwich (routed insertion):** each tenant's route to
  the other points at the firewall's leg in its own VRF. The firewall
  is the only bridge between the VRFs.
- **Act 2 — PBR steering:** even *same-tenant* traffic can be detoured
  through the firewall with a route-map (`set ip next-hop`). No routing
  change — a policy grabs packets mid-flight.

## Topology (delta from the 01-underlay base)

```
                    spine1        spine2
                      |  \       /  |
                      |    \   /    |
                      |     \ /     |
                    leaf1    X    leaf2
                    / | \   / \     |
              e3   e5   e6         e3
               |    |    |          |
            host1  fw:eth1 fw:eth2  host2
          Ten-A    VLAN91   VLAN92  Ten-B
        10.100.10  Ten-A    Ten-B   10.200.10
                   .91.10   .92.10
```

fw = Alpine, IP forwarding + nftables. Its eth1 lives in Tenant-A's
service VLAN 91, eth2 in Tenant-B's service VLAN 92 — the same box has
a leg in each tenant, and *it* decides what crosses.

## Why the sandwich beats the leak

| | 05b RT leak | 15 sandwich |
|---|---|---|
| Path | leaf routes directly | leaf → **fw** → leaf |
| Inspection | none | every packet |
| TTL (predicted) | 63 | **61** (extra fw hop = your proof) |
| Failure mode | silent full access | fw down = isolation (fail-closed) |
| Who owns policy | network (RTs) | security (fw rules) |

## Day in the life of a packet — host1 → host2 through the checkpoint

**Hop 1 — leaf1 (Tenant-A):** dst 10.200.10.10 matches the **static**
`via 10.100.91.10` — not a leaked EVPN route. Next-hop is in VLAN 91,
local on leaf1 → deliver to fw eth1. VERIFY: `show ip route 10.200.10.0/24
vrf Tenant-A` shows static, no `%Tenant-B`.
**Hop 2 — fw:** routes eth1→eth2 (ip_forward), nftables FORWARD chain
decides. TTL −1. This is the checkpoint.
**Hop 3 — leaf1 (Tenant-B!):** fw's eth2 frame arrives in VLAN 92 —
now inside Tenant-B. Normal Session-4 routing to host2 (via leaf2 if
remote). TTL −1 (+1 more at leaf2's egress bridge... net observed TTL
to confirm live).
**The return** must traverse the fw too (Tenant-B's static) — and the
firewall's conntrack matches it to the outbound session. Symmetry is
*designed in* here because both statics point at the same box; Act 2's
PBR deliberately breaks that symmetry to teach it.

## Files

`labs/15-firewall-insertion/` — topology.clab.yml, configs/leaf{1,2}.cfg,
verify.md (the three acts + predictions), break-it.md (4 drills).

## Flashcards

| Q | A |
|---|---|
| Sandwich vs leak in one line? | Leak = connectivity without policy; sandwich = the firewall IS the route between VRFs. |
| Why TTL 61 not 63? | The fw is a router in the path — extra decrement per direction is the transit proof. |
| fw dies — what happens? | Fail-closed: statics point at a dead next-hop, tenants isolated. (And a static stays in the RIB pointing at nothing — the blackhole break-it.) |
| Why is Act 2's return not steered? | PBR only grabs packets at its ingress interface; the reverse path never hits that policy — asymmetry unless you steer both sides. |
| ePBR/ITD here? | Verified absent on this platform. Probes/health-based steering is the gap; ip-sla track on statics is the poor-man's fix. |

## Next

Session 16 — Transit routing: the fabric carrying traffic *between two
external domains* (dual L3Out), and then deliberately refusing to.
