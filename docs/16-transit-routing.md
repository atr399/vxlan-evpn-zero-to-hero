# Session 16 — Transit Routing (the fabric as a highway between externals)

> **STATUS: UNTESTED DESIGN.** All-proven-tech (Session 9 ×2 + route-maps);
> the one genuine unknown is flagged in verify.md step 5's gotcha.

## Mental model
Session 9 connected the fabric to ONE outside world. Add a second
(WAN west, Internet east) and a new question appears: should traffic be
able to enter one door and leave the other? Sometimes yes (DC as transit
between branch WAN and internet). Sometimes emphatically no (you are not
your ISP's backbone). This lab builds the transit, proves it with an
external-to-external ping that never touches a fabric host, then kills
it surgically with a route-map — connectivity as a *policy choice*.

## The packet (headline flow)
host_wan → extwan → [eBGP] → leaf1 → **L3VNI 50001 across the fabric**
→ leaf2 → [eBGP] → extinet → host_inet. Two Type-5 re-originations back
to back: each border learns an external prefix and re-advertises it into
EVPN; the opposite border re-advertises EVPN back out to ITS external.
The fabric is invisible to both routers — they just see AS 65000 in the
path.

## Flashcards
| Q | A |
|---|---|
| What makes the fabric a transit? | Each border re-originates the OTHER side's Type-5 out its eBGP session — in by one door, out the other. |
| AS-path seen by extwan for the east prefix? | 65000 65100 — the fabric appears as one transit AS. |
| How do you refuse transit but keep local reachability? | Outbound route-map on each eBGP session denying the *other external's* prefixes; fabric-origin prefixes still permitted. |
| Half-filtered transit symptom? | One-way blackhole: requests delivered, replies unroutable. Filter both borders. |

## Next
Session 17 — a service that *terminates* traffic instead of forwarding it.
