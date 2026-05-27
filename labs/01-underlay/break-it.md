# Session 1: Break It On Purpose

The underlay works. Now we make it fail in deliberate ways and watch
what happens. This is where real understanding comes from — anyone can
type configs, but seeing a protocol fail and recover tells you what
each piece actually does.

Do these in order. Each exercise leaves the lab in a known state for
the next one.

---

## Exercise 1: Link failure and reconvergence

**Scenario:** A cable between spine1 and leaf1 fails. Does the fabric
keep working?

**Before:** Pings from leaf1 to leaf2's loopback (`ping 10.0.0.22 source
10.0.0.21`) work and traffic uses ECMP across both spines.

**Action:** On spine1, shut the link to leaf1.

```
spine1# configure terminal
spine1(config)# interface Ethernet1/1
spine1(config-if)# shutdown
spine1(config-if)# end
```

**Observe within 30 seconds:**

On leaf1:

```
show ip ospf neighbors
```

You should now see only ONE neighbor (the spine2 adjacency). The
spine1 adjacency is gone.

```
show ip route 10.0.0.22
```

Only one path now — via spine2 (10.10.3.0). ECMP collapsed to a single
path.

**Test connectivity:**

```
ping 10.0.0.22 source 10.0.0.21
```

Still works! Traffic now goes leaf1 → spine2 → leaf2. The fabric stayed
up because we had redundancy.

**Teaching point:** This is the entire reason a spine-leaf has a *full
mesh* between leaves and spines. With two spines, any single link or
spine failure is survivable. With one spine, it's a single point of
failure. Production fabrics use 4+ spines for the same reason.

**Restore:**

```
spine1# configure terminal
spine1(config)# interface Ethernet1/1
spine1(config-if)# no shutdown
spine1(config-if)# end
```

Within a few seconds, OSPF reforms and ECMP returns. Verify with
`show ip route 10.0.0.22` — back to two paths.

---

## Exercise 2: MTU mismatch (the silent killer)

**Scenario:** Someone changes MTU on one side of a link but not the
other. OSPF behavior is subtle here.

**Action:** On leaf1, change Eth1/1's MTU to 1500.

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# mtu 1500
leaf1(config-if)# end
```

**Wait 60 seconds, then check:**

```
show ip ospf neighbors
```

Watch the spine1 adjacency. You'll see it go from FULL → EXSTART → DOWN
in a loop. Sometimes it stays stuck at EXSTART for a while.

**Why this happens:** OSPF's DBD (Database Description) packets need to
fit through the link. When one side tries to send a DBD with up to 9216
bytes and the other can only accept 1500, the larger packets get
dropped. The adjacency never gets past the initial DB exchange.

Note that Hellos still pass through fine (they're small). So OSPF might
get to TWO-WAY but never to FULL.

**Why this is dangerous in real life:** If the MTU mismatch is the
other way around (underlay all 1500, you forgot to set 9216 anywhere),
OSPF works fine because small Hellos and DBDs fit. **But VXLAN data
plane drops packets** because each encapsulated frame is 50 bytes
larger than the original. Result: control plane looks healthy, data
plane silently fails.

The lesson: **always check MTU on both ends of every link**, even if
OSPF is up.

**Restore:**

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# mtu 9216
leaf1(config-if)# end
```

OSPF should recover to FULL within ~30 seconds.

---

## Exercise 3: Wrong OSPF network type

**Scenario:** Someone forgets `ip ospf network point-to-point` on one
side. OSPF defaults back to broadcast mode on Ethernet.

**Action:** On leaf1, remove the network type.

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# no ip ospf network point-to-point
leaf1(config-if)# end
```

**Observe:** The adjacency may flap once and then come back up, but
something has changed:

```
show ip ospf neighbors
```

Look at the **State** column. Previously you saw `FULL/ -` (the dash
meaning "no DR concept here"). Now you might see `FULL/BDR` or
`FULL/DR` — DR election has kicked in because one side thinks this is
broadcast.

**Why this matters:** On a true point-to-point Ethernet link, DR
election is **pure overhead** — there are only two routers, so neither
needs to act as a DR for others. It also adds latency to convergence
(DR election takes 40 seconds by default for the wait timer).

In a small lab it doesn't visibly break anything. In a large fabric
with hundreds of P2P links, it's a real performance issue during
failovers.

**Restore:**

```
leaf1# configure terminal
leaf1(config)# interface Ethernet1/1
leaf1(config-if)# ip ospf network point-to-point
leaf1(config-if)# end
```

---

## Exercise 4: Router-ID collision

**Scenario:** Two devices end up with the same OSPF router-id (e.g. an
operator typo). What happens?

**Action:** Make spine2's router-id match spine1.

```
spine2# configure terminal
spine2(config)# router ospf UNDERLAY
spine2(config-router)# router-id 10.0.0.11
spine2(config-router)# end
```

Then bounce the OSPF process (router-id changes don't take effect on
live OSPF in NX-OS without a clear):

```
spine2# clear ip ospf process UNDERLAY
```

**Observe on leaf1:**

```
show ip ospf neighbors
```

The adjacency to one of the spines will be unstable or you'll see
strange "Neighbor ID" duplicates. OSPF identifies routers by their
router-id; two routers claiming the same ID confuses the LSA database.

You may see log messages like:

```
%OSPF-4-DUP_RTRID_AREA: OSPF-UNDERLAY router 10.0.0.11 area 0.0.0.0 ...
```

**Teaching point:** OSPF router-id is a unique identity, not just a
label. Always set it explicitly to your loopback IP. Don't rely on
auto-selection (which picks the highest-numbered interface IP) because
adding/removing interfaces can silently change it.

**Restore:**

```
spine2# configure terminal
spine2(config)# router ospf UNDERLAY
spine2(config-router)# router-id 10.0.0.12
spine2(config-router)# end
spine2# clear ip ospf process UNDERLAY
```

---

## Exercise 5 (optional): Watch convergence in real time

Set up two SSH sessions to leaf1.

**Session 1**: continuous ping to leaf2's loopback:

```
leaf1# ping 10.0.0.22 source 10.0.0.21 count 9999
```

**Session 2**: shut spine1's link to leaf1 (as in Exercise 1).

Watch the ping output. You should see at most 1-2 packet drops before
traffic re-routes through spine2. OSPF default Dead Interval is 40
seconds, but with point-to-point networks and BFD-like fast hello
behavior, convergence is much faster than that — typically under a
second on a healthy device.

This 1-2 packet drop is the **measurable cost of a link failure** in
this design. In session 2 (BGP overlay) we'll see BGP convergence
behave differently, and in session 7 (eBGP underlay) we'll see how
to tune it for sub-100ms convergence in production.

---

## After these exercises

If you understood why each break caused what it did, you're ready for
the overlay.

If any of these confused you, **stay on session 1**. Tear the lab down,
redeploy, and run through the exercises again until each failure mode
makes intuitive sense. The whole stack rests on the underlay being
boring and reliable — if you skim this layer, you'll spend hours later
chasing problems that were rooted here.

Reset to clean state:

```bash
./scripts/reset.sh 01-underlay
```
