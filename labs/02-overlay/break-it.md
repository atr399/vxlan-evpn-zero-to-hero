# Session 2: Break It On Purpose

Five exercises that expose how BGP-EVPN behaves under failure. Do them
in order. Each restores state before the next.

---

## Exercise 1: Lose a spine — does the overlay survive?

**Scenario**: spine1 dies (or you take it down for maintenance). With
two spines acting as RRs, what happens to BGP and to the data path?

**Before**: Both BGP sessions on leaf1 are Established.

```
leaf1# show bgp l2vpn evpn summary
```

**Action**: On spine1, shut down BGP entirely.

```
spine1# configure terminal
spine1(config)# router bgp 65000
spine1(config-router)# shutdown
spine1(config-router)# end
```

(`shutdown` under `router bgp` administratively disables the BGP
process without removing config.)

**Observe within 3 minutes** (BGP holdtime is 180s by default):

```
leaf1# show bgp l2vpn evpn summary
```

You should see the session to 10.0.0.11 (spine1) drop out of
Established. The session to 10.0.0.12 (spine2) stays up.

**Teaching point**: This is why you have **two spines/RRs**. Losing
one is survivable. Session 3 onward, EVPN routes are still received
via spine2. Production fabrics often use 4+ spines for the same
reason at higher scale.

**Note on convergence speed**: 180 seconds is *very slow*. In a real
deployment you'd run BFD for sub-second peer-down detection. We'll
add BFD in session 7.

**Restore**:

```
spine1# configure terminal
spine1(config)# router bgp 65000
spine1(config-router)# no shutdown
spine1(config-router)# end
```

Session re-establishes in ~10 seconds.

---

## Exercise 2: Wrong update-source

**Scenario**: Someone forgets `update-source loopback0` on one side.
What happens?

**Action**: On leaf1, remove update-source from the spine1 session.

```
leaf1# configure terminal
leaf1(config)# router bgp 65000
leaf1(config-router)# neighbor 10.0.0.11
leaf1(config-router-neighbor)# no update-source loopback0
leaf1(config-router-neighbor)# end
```

Then clear the session to force a re-establishment:

```
leaf1# clear ip bgp 10.0.0.11
```

**Observe**:

```
leaf1# show bgp l2vpn evpn summary
```

The session to 10.0.0.11 will likely be stuck in `Active` or `Idle`
state, never Established.

**Why this happens**: Without `update-source loopback0`, leaf1 sends
TCP SYN packets sourced from its **physical interface IP**
(10.10.1.1, the link toward spine1). spine1's BGP config says "I
accept connections from neighbor 10.0.0.21" — but leaf1 is contacting
from 10.10.1.1. The TCP SYN arrives, spine1 doesn't recognize the
source as a configured neighbor, and the session never forms.

The session might attempt to come up the other direction (spine1
contacting 10.0.0.21), but BGP's peer matching is bidirectional —
both sides need to agree on which IPs are talking.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# router bgp 65000
leaf1(config-router)# neighbor 10.0.0.11
leaf1(config-router-neighbor)# update-source loopback0
leaf1(config-router-neighbor)# end
leaf1# clear ip bgp 10.0.0.11
```

---

## Exercise 3: BGP lives independent of physical paths

**Scenario**: We shut a physical link to prove BGP rides on the
loopback, not on the physical interface.

**Before**: All BGP sessions Established. Two OSPF paths from leaf1 to
spine1's loopback (direct via Eth1/1, and indirect via spine2 and
leaf2).

Actually wait — with our topology, leaf1 only has *one* path to
spine1's loopback in normal state (direct via Eth1/1), because the
indirect path would require leaf1 → spine2 → leaf2 → spine1, and we
have no leaf-leaf links. So shutting the leaf1-spine1 link will
**eventually disconnect** the BGP session unless the OSPF topology
provides an alternative.

Let's adjust: instead of shutting the physical link, we shut the
*OSPF process on that interface*, leaving the physical link up but
unusable for routing.

Actually the cleaner demo: shut Eth1/1 on leaf1 (the direct link to
spine1), and observe whether the BGP session to spine1 survives via
the indirect path. With our 2-spine, 2-leaf, full-mesh fabric, the
indirect path exists: leaf1 → spine2 → spine2-leaf2-link → leaf2 →
... wait, leaf2 doesn't peer in OSPF with spine1 through an
intermediate leaf.

Look at leaf1's route table:

```
leaf1# show ip route 10.0.0.11
```

You'll see only one path: direct via Eth1/1 → 10.10.1.0. There is
**no alternate path** to spine1's loopback from leaf1, because in our
4-node spine-leaf there are no leaf-to-leaf or spine-to-spine links.

**This is a teaching insight in itself**: spine-leaf with 2 spines
gives you redundancy at the **fabric level** (lose a spine, the other
takes over), but **not for individual control-plane sessions**. Each
leaf has exactly one path to each spine.

**Action**: Shut Eth1/1 on leaf1 and observe what dies.

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# shutdown
leaf1(config-if)# end
```

**Observe**:

```
leaf1# show ip ospf neighbors
leaf1# show bgp l2vpn evpn summary
```

OSPF: only 1 neighbor (spine2). The spine1 neighbor is gone.
BGP: session to 10.0.0.11 (spine1) goes down within the holdtime.
BGP session to 10.0.0.12 (spine2) stays up.

**Teaching point**: Loopback-sourced BGP survives **link failures
where an alternate path exists**. In our minimal topology, there's
no alternate path leaf1-to-spine1, so the session dies anyway. But —
the *fabric* still works, because spine2's RR-reflected routes still
flow to leaf1 via the surviving session.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# no shutdown
leaf1(config-if)# end
```

---

## Exercise 4: Remove route-reflector-client on a spine

**Scenario**: An operator typo — `route-reflector-client` is removed
from spine1's session to leaf1. What breaks?

In session 2 this is hard to observe directly because no routes are
flowing yet. But the configuration itself is the demonstration.

**Action**:

```
spine1# configure terminal
spine1(config)# router bgp 65000
spine1(config-router)# neighbor 10.0.0.21
spine1(config-router-neighbor)# address-family l2vpn evpn
spine1(config-router-neighbor-af)# no route-reflector-client
spine1(config-router-neighbor-af)# end
```

```
spine1# show bgp l2vpn evpn neighbors 10.0.0.21 | include "Route-Reflector"
```

You should now see no "Route-Reflector Client" line.

**Teaching point**: The session stays Established because nothing
prevents an iBGP session without RR-client designation. But once
session 3 introduces real routes, spine1 would receive routes from
leaf1 and **fail to reflect them to leaf2** (iBGP rule: don't
re-advertise iBGP routes to other iBGP peers).

Result: leaf2 wouldn't learn about leaf1's hosts. host1-host2 ping
would fail. The control plane silently has a hole.

**This is one of the more dangerous misconfigurations** because
neither BGP state nor any error message hints at it. You only see it
when traffic doesn't flow.

**Restore**:

```
spine1# configure terminal
spine1(config)# router bgp 65000
spine1(config-router)# neighbor 10.0.0.21
spine1(config-router-neighbor)# address-family l2vpn evpn
spine1(config-router-neighbor-af)# route-reflector-client
spine1(config-router-neighbor-af)# end
```

---

## Exercise 5: Watch a BGP session come up in detail

**Scenario**: Educational — let's see the BGP state machine transitions
in real time.

**Action**: On leaf1, in one SSH session, enable BGP event tracing:

```
leaf1# debug ip bgp events
leaf1# debug ip bgp updates
```

In another SSH session to leaf1, clear the session:

```
leaf1# clear ip bgp 10.0.0.11
```

Watch the first session's output. You'll see (roughly):

1. `BGP session reset`
2. `Neighbor 10.0.0.11 transitioning Idle -> Connect`
3. `Active -> OpenSent` (sending Open message)
4. `OpenSent -> OpenConfirm` (Open exchange done)
5. `OpenConfirm -> Established` (keepalives exchanged)

**Teaching point**: BGP's state machine is well-defined and predictable.
Each transition has a clear cause. When you see a session stuck in
Active or OpenSent, the state name tells you exactly which step is
failing.

**Stop the debug** when done:

```
leaf1# undebug all
```

(Forgetting to undebug can fill the device's log buffer with noise
during normal operations.)

---

## After these exercises

The control plane is built and you understand how it fails. If you
can answer:

- Why losing one spine is survivable
- Why a missing `update-source` prevents the session from forming
- Why missing `route-reflector-client` silently breaks tenant routing

…then you're ready for session 3, where we put this control plane to
work distributing actual MAC/IP information.

Reset to clean state:

```bash
./scripts/reset.sh 02-overlay
```
