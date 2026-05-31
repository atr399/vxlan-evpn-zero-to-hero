# Session 3: Break It On Purpose

Five exercises that reveal how L2VNI actually works by breaking it in
revealing ways. Verify Session 3 works end-to-end first, then run
these in order. Each restores state before the next.

---

## Exercise 1: Mismatched VNI on the two leaves

**Scenario**: An operator typo. leaf1 maps VLAN 10 to VNI 10010, but
leaf2 maps VLAN 10 to VNI 10011. What happens?

**Action**: On leaf2, remap VLAN 10 to a different VNI.

```
leaf2# configure terminal
leaf2(config)# vlan 10
leaf2(config-vlan)# no vn-segment 10010
leaf2(config-vlan)# vn-segment 10011
leaf2(config-vlan)# end
```

Also update the EVPN block to match:

```
leaf2# configure terminal
leaf2(config)# no evpn
leaf2(config)# evpn
leaf2(config-evpn)# vni 10011 l2
leaf2(config-evpn-evi)# rd auto
leaf2(config-evpn-evi)# route-target import auto
leaf2(config-evpn-evi)# route-target export auto
leaf2(config-evpn-evi)# end
```

**Observe**:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11
```

**Ping fails.** No replies. But everything *looks* fine on the surface:
- BGP sessions are still Established
- Both leaves have a VTEP up
- `show nve peers` might still show the peer

The fail is silent and confusing. The two leaves are advertising
Type-2 routes with **different VNIs** and **different RDs/RTs**.
Neither leaf imports the other's MAC into the same L2 segment.

**Why this is a real-world hazard**: in production with dozens of
VNIs, this is the #1 cause of "the host can't reach its neighbor
even though VXLAN is up." The mistake is tiny; the failure is
opaque.

**How to spot it**:

```
leaf2# show bgp l2vpn evpn route-type 2
```

You'd see leaf1's MACs being received from BGP, but they have RT
matching VNI 10010. leaf2 is now configured for VNI 10011, so those
routes don't import.

Use `show bgp l2vpn evpn` and check the RT extended-communities on
incoming routes — if they don't match what's configured locally,
that's your bug.

**Restore**:

```
leaf2# configure terminal
leaf2(config)# vlan 10
leaf2(config-vlan)# no vn-segment 10011
leaf2(config-vlan)# vn-segment 10010
leaf2(config-vlan)# exit
leaf2(config)# no evpn
leaf2(config)# evpn
leaf2(config-evpn)# vni 10010 l2
leaf2(config-evpn-evi)# rd auto
leaf2(config-evpn-evi)# route-target import auto
leaf2(config-evpn-evi)# route-target export auto
leaf2(config-evpn-evi)# end
```

Then trigger a re-learn:

```
leaf2# clear ip bgp 10.0.0.11
leaf2# clear ip bgp 10.0.0.12
```

Verify ping recovers.

---

## Exercise 2: Remove host-reachability protocol bgp

**Scenario**: We deliberately revert to flood-and-learn behavior to
see how it compares.

**Action**: On leaf1:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# no host-reachability protocol bgp
leaf1(config-if-nve)# end
```

**Observe**:

```
leaf1# show interface nve1 | include "Host Reachability"
```

Should now show `Host Reachability Mode: flood-and-learn`.

Then check the EVPN routes leaf1 is advertising:

```
leaf1# show bgp l2vpn evpn route-type 2
```

You'll see leaf1 **stops advertising its local MACs** via Type-2. The
EVPN control plane is no longer learning MACs from leaf1.

Ping might still work or might break — depends on timing and what's
still cached. In production this is a regression; flood-and-learn
worked in 2012 but doesn't scale.

**Teaching point**: BGP-EVPN's value is that one line. Without
`host-reachability protocol bgp`, you have VXLAN tunnels but the
control plane is dark. This is what flood-and-learn looked like in
the old days.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# host-reachability protocol bgp
leaf1(config-if-nve)# end
```

Verify EVPN MAC routes return.

---

## Exercise 3: Shut the NVE interface

**Scenario**: Brutal — what happens when the VTEP itself goes down?

**Action**:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# shutdown
leaf1(config-if-nve)# end
```

**Observe within seconds**:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11
```

Ping fails immediately. From leaf2:

```
leaf2# show nve peers
```

The peer 10.0.1.21 (leaf1's VTEP) is gone or in Down state.

```
leaf2# show bgp l2vpn evpn route-type 3
```

You'll only see leaf2's own Type-3 route. Leaf1's was withdrawn.

```
leaf2# show l2route evpn mac all
```

leaf1's MACs were withdrawn from the MAC table.

**Teaching point**: When the NVE goes down, NX-OS withdraws all
EVPN routes for that VTEP. Other leaves correctly remove the
corresponding entries. The fabric is self-healing without operator
intervention.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# no shutdown
leaf1(config-if-nve)# end
```

Peer relationship comes back up within ~10 seconds, MAC tables
repopulate after the next traffic.

---

## Exercise 4: Wrong VTEP source interface

**Scenario**: Source the NVE from loopback0 (router-id) instead of
loopback1 (VTEP). What goes wrong?

**Action** on leaf1:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# source-interface loopback0
leaf1(config-if-nve)# end
```

**Observe**:

```
leaf1# show nve interface nve1
```

VTEP source is now 10.0.0.21 (loopback0).

```
leaf2# show nve peers
```

leaf2 might now show TWO peers — the old 10.0.1.21 (slowly aging out)
and a new 10.0.0.21. Or just the new one. Either way, the fabric is
confused.

**Why this matters**: In simple labs you can usually source from any
loopback and it works. In **vPC** designs (Session 6), the VTEP IP is
specifically designed to be shared between two physical leaves, while
loopback0 (router-id) must be unique per leaf. If you reuse the same
loopback for both purposes, vPC breaks.

The discipline of "loopback0 = router-id, loopback1 = VTEP" is what
prevents this whole class of bug.

**Restore**:

```
leaf1# configure terminal
leaf1(config)# interface nve1
leaf1(config-if-nve)# source-interface loopback1
leaf1(config-if-nve)# end
leaf1# clear ip bgp *
```

Wait ~30 seconds for things to settle. Verify with `show nve peers` on
leaf2.

---

## Exercise 5: Capture a real VXLAN packet (educational)

**Scenario**: Let's actually see VXLAN encapsulation on the wire.
This isn't a break — it's a demonstration.

**Setup**: From the VM shell, start a tcpdump on the underlay link
between leaf1 and spine1. This requires running tcpdump inside leaf1's
container namespace:

```bash
sudo docker exec clab-vxlan-evpn-leaf1 tcpdump -i eth1 -nn -e -c 5 'udp port 4789'
```

`udp port 4789` is the IANA-assigned VXLAN port.

In another terminal, start a continuous ping:

```bash
docker exec clab-vxlan-evpn-host1 ping 10.100.10.11
```

**Observe the tcpdump output**. You'll see lines like:

```
12:34:56.789 ... 10.0.1.21.X > 10.0.1.22.4789: VXLAN, flags [I] (0x08), vni 10010
  ARP, Request who-has 10.100.10.11 tell 10.100.10.10, length 28
```

Read that carefully — it's the heart of VXLAN:

- **Outer header** (the IP/UDP routing layer): from 10.0.1.21 (leaf1's
  VTEP) to 10.0.1.22 (leaf2's VTEP)
- **VXLAN header**: VNI 10010
- **Inner packet**: the host's original Ethernet frame (in this case
  an ARP), with the host MACs

This is the moment to **see** what we've been building. Underlay IP
addresses on the outside, tenant traffic on the inside, separated by
the VXLAN header.

`Ctrl-C` to stop both the tcpdump and the ping when you've seen
enough.

**Teaching point**: VXLAN is just **UDP**. There's nothing magical at
the network layer — it's a Layer 2 frame stuffed inside a UDP packet.
The fabric forwards it like any other UDP. That simplicity is the
genius of the design.

---

## After these exercises

If you can answer:

- Why a VNI mismatch causes silent ping failures
- What `host-reachability protocol bgp` actually controls
- Why we use loopback1 (not loopback0) for the VTEP source
- What a VXLAN packet on the wire actually looks like

…you understand L2VNI at a working level. Session 4 (anycast gateway)
is the natural next layer.

Reset to clean state:

```bash
./scripts/reset.sh 03-l2vni
```

Don't forget to re-run the manual host IP config after redeploy.
