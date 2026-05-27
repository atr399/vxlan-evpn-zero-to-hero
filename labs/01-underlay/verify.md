# Session 1: Verification

Run through this checklist after `deploy.sh 01-underlay` completes. If
anything doesn't match, debug before moving on.

## Login

```bash
ssh admin@clab-vxlan-evpn-spine1     # password: admin
```

Repeat for spine2, leaf1, leaf2 as needed.

## Check 1: OSPF neighbors are FULL

On any device:

```
show ip ospf neighbors
```

**On a spine** (e.g. spine1):

```
 Neighbor ID     Pri State            Up Time  Address         Interface
 10.0.0.21         1 FULL/ -          00:01:23 10.10.1.1       Eth1/1
 10.0.0.22         1 FULL/ -          00:01:20 10.10.2.1       Eth1/2
```

Two neighbors, both FULL. Each spine sees both leaves.

**On a leaf** (e.g. leaf1):

```
 Neighbor ID     Pri State            Up Time  Address         Interface
 10.0.0.11         1 FULL/ -          00:01:23 10.10.1.0       Eth1/1
 10.0.0.12         1 FULL/ -          00:01:21 10.10.3.0       Eth1/2
```

Two neighbors. Each leaf sees both spines.

**What to check if a neighbor isn't FULL:**

- Stuck in `INIT` — the other side isn't sending Hello packets back.
  Check `show interface Eth1/X` on the far side; interface might be down
  or unconfigured.
- Stuck in `EXSTART` / `EXCHANGE` — almost always an MTU mismatch. The
  two ends are trying to send DBD packets larger than the link can
  forward. Run `show interface Eth1/X | include MTU` on both sides;
  they must match.

## Check 2: All loopbacks are in the route table

On leaf1:

```
show ip route ospf
```

You should see 3 OSPF-learned routes — the two spine loopbacks and the
other leaf's loopback:

```
10.0.0.11/32, ubest/mbest: 1/0
    *via 10.10.1.0, Eth1/1, [110/41], ..., ospf-UNDERLAY, intra
10.0.0.12/32, ubest/mbest: 1/0
    *via 10.10.3.0, Eth1/2, [110/41], ..., ospf-UNDERLAY, intra
10.0.0.22/32, ubest/mbest: 2/0
    *via 10.10.1.0, Eth1/1, [110/81], ..., ospf-UNDERLAY, intra
    *via 10.10.3.0, Eth1/2, [110/81], ..., ospf-UNDERLAY, intra
10.0.1.22/32, ubest/mbest: 2/0
    *via 10.10.1.0, Eth1/1, [110/81], ..., ospf-UNDERLAY, intra
    *via 10.10.3.0, Eth1/2, [110/81], ..., ospf-UNDERLAY, intra
```

**The important thing to notice:** the routes to leaf2 (10.0.0.22 and
10.0.1.22) have **two** next-hops — one via each spine. This is
**ECMP** (Equal Cost Multi-Path) and it's what gives VXLAN traffic two
paths to choose from later. If you only see one next-hop, one of the
spine-leaf links isn't bringing OSPF up.

## Check 3: End-to-end loopback ping with ECMP

From leaf1:

```
ping 10.0.0.22 source 10.0.0.21
```

Should succeed with ~0ms latency (it's all in software on the same VM).

For the VTEP loopback (which is what really matters for VXLAN later):

```
ping 10.0.1.22 source 10.0.1.21
```

Also should succeed. This is the ping that proves VXLAN will work once
we turn it on.

## Check 4: MTU is 9216 on every underlay interface

On each device:

```
show interface | include "Ethernet|MTU"
```

You should see `MTU 9216 bytes` on every `Ethernet1/X` that's part of
the fabric. Loopbacks default to a different MTU; that doesn't matter.

**If you see 1500 on any underlay link**, fix it now. This is the most
common "everything works for OSPF but VXLAN breaks" bug.

## Check 5: OSPF cost looks sane

On a leaf:

```
show ip ospf interface brief
```

```
 Interface  PID    Area            Cost   State    Neighbors  Status
 Lo0        UNDERLAY 0.0.0.0          1    LOOPBACK 0          up
 Lo1        UNDERLAY 0.0.0.0          1    LOOPBACK 0          up
 Eth1/1     UNDERLAY 0.0.0.0         40    P2P      1          up
 Eth1/2     UNDERLAY 0.0.0.0         40    P2P      1          up
```

Cost 40 on the P2P links is NX-OS's default for a 1G-equivalent interface.
The exact number doesn't matter for now; what matters is that both
spine-facing interfaces have the **same** cost so ECMP works.

## Check 6: OSPF database sanity

```
show ip ospf database
```

You should see 4 Router LSAs (one per device, since all are in Area 0).
No external (Type 5) LSAs, no summary (Type 3) LSAs — we're not
redistributing anything and there's only one area.

## What success looks like, summarized

- 4 OSPF adjacencies total in the fabric, all FULL
- Every device's route table contains every other device's loopback
- ECMP active: leaves see two next-hops to each other
- Pings work loopback-to-loopback
- MTU 9216 on every underlay link

If all six checks pass, the underlay is done. Move to the break-it
exercises before going to Session 2.
