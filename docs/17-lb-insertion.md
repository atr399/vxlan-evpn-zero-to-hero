# Session 17 — Load Balancer Insertion (one-armed, and why SNAT exists)

> **STATUS: UNTESTED DESIGN.** ITD (NX-OS native LB) verified ABSENT on
> this platform (CLI gate July 2026) — noted here as a finding; the lab
> uses haproxy, which also better matches what most shops actually run.

## Mental model
A VIP (10.100.99.99) that belongs to no subnet and no switch — it lives
on the load balancer's loopback, made reachable by ONE static route.
Clients talk to the VIP; haproxy picks a backend. The entire lab funnels
into one lesson: **the return path**. In one-armed mode the backend's
reply naturally goes straight back to the client — bypassing the LB —
and the client RSTs a session it thinks it opened elsewhere. The fix is
SNAT (`source` in haproxy): make the LB the client, so replies must
return through it. You will break this on purpose and watch the triangle
with tcpdump.

## Design forks worth teaching
- **One-armed + SNAT** (this lab): simple, scales, loses client IP at
  the backend (X-Forwarded-For exists for a reason).
- **Inline/routed**: LB between client and servers — keeps client IP,
  but ALL traffic transits the LB (Session 15's sandwich, with sockets).
- **DSR**: replies bypass the LB *by design* — needs VIP-on-loopback +
  ARP games on every backend, and interacts weirdly with EVPN ARP
  suppression (break-it #3).

## Flashcards
| Q | A |
|---|---|
| How is an off-subnet VIP reachable? | A /32 static on the leaf pointing at the LB's real IP; the LB owns the VIP on lo. |
| Why does removing SNAT break everything? | Backend replies directly to the client with its OWN address; the client never associates it with the VIP session → RST. |
| What did SNAT cost you? | The backend sees the LB as client — real client IP is gone (hence X-Forwarded-For). |
| ITD on this platform? | Verified absent — feature gate, July 2026. |

## Next
The service-insertion trilogy (15/16/17) is complete: filter, transit,
terminate — three things a fabric does with traffic besides deliver it.
