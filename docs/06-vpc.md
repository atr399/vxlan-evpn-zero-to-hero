# Session 6: vPC (Multi-Chassis LAG)

**Prerequisites**: Session 5b working. Multi-VRF with route leak.
Topology change: this session requires the **expanded topology**
with peer-link and dual-homed host (Sessions 6+ use additional
clab links).

**Goal**: Dual-home host1 to both leaf1 AND leaf2 so host1 has two
physical NICs in an LACP bond. The two leaves act as a single
logical L2 switch from host1's perspective. If leaf1 dies, host1
keeps working via leaf2 with no host reconfiguration.

**Lab folders**: `labs/06a-vpc-base/`, `labs/06b-vpc-host-bond/`
(coming), `labs/06c-vpc-vxlan/` (coming)

**Estimated time**: 60 minutes (this is the densest session in the
curriculum). 6a alone is ~20 min; 6b and 6c each ~20 min.

---

## Mental model

In a real data center, every server has **two** physical NICs.
Each NIC connects to a different leaf. The two NICs form an LACP
bond on the server side. From the server's perspective: one logical
link with double the bandwidth and full leaf-failure protection.

The challenge: **two physical switches need to pretend to be one
switch**. From the server, the bond looks like a single peer
sending consistent LACP and MAC behavior. The two leaves coordinate
behind the scenes — that coordination is **vPC** (virtual Port-
Channel).

Three new physical concepts:

| Component | Purpose |
|-----------|---------|
| **Peer-link** | Bulk traffic link between leaf1 and leaf2 (port-channel100). Carries inter-leaf data plus vPC control messages. |
| **Peer-keepalive** | Out-of-band heartbeat to detect "is my peer alive?" Separate physical link from the peer-link. |
| **vPC member ports** | Ports facing the host. leaf1 Eth1/3 and leaf2 Eth1/3 are both members of vPC 10. |

Three layers of detection answer the question "what's my peer's
state?":

1. **Both links up** → vPC healthy, both leaves forward traffic
2. **Peer-link down, keepalive up** → "isolated" mode, secondary
   leaf shuts its vPC ports to avoid split-brain
3. **Both links down** → catastrophic; assume split-brain, may
   need manual recovery

Most production deployments add a 4th detection layer (BGP+BFD)
but the 3-layer base is what vPC requires.

---

## Why three checkpoints (6a, 6b, 6c)

vPC + VXLAN is the most failure-prone combination in the
curriculum. Cisco's documentation on the integration is patchy.
Real deployments routinely hit:
- Peer-link MTU mismatch
- Asymmetric LACP behavior between leaves
- VTEP advertisement conflicts (each leaf advertising its own
  loopback1 vs. the shared anycast)
- Underlay convergence interactions with vPC

Splitting into three checkpoints means: if 6c is broken because of
VXLAN integration, we don't lose the vPC base from 6a/6b.

```
6a: Peer-link + peer-keepalive + vPC domain
    → Checkpoint: vPC peer adjacency formed, but no host bonded yet

6b: vPC member port + host LACP bond
    → Checkpoint: host1 has working LACP bond, can ping host2 via the bond

6c: vPC + VXLAN integration (shared VTEP)
    → Checkpoint: EVPN advertises host1 via shared VTEP, not per-leaf
    → Checkpoint: leaf failure (shutdown one leaf) — host1 traffic survives
```

Each checkpoint is independently testable. If we get to 6b
successfully, you can stop there and have a working vPC + VXLAN
fabric — without the shared-VTEP optimization in 6c.

---

## Part 1: Session 6a — vPC Base

### What we're adding (on top of Session 5b)

**On both leaves**:

```
feature vpc
feature lacp

vpc domain 10
  peer-switch
  role priority 1                                    # primary (leaf2 gets 2)
  peer-keepalive destination 10.20.0.1 source 10.20.0.0 vrf default
  delay restore 150
  peer-gateway
  ipv6 nd synchronize
  ip arp synchronize

interface Ethernet1/4
  description vPC peer-link member
  switchport
  switchport mode trunk
  switchport trunk allowed vlan 1,10,20,30,40,98,99
  channel-group 100 mode active
  no shutdown

interface port-channel100
  description vPC peer-link
  switchport mode trunk
  switchport trunk allowed vlan 1,10,20,30,40,98,99
  spanning-tree port type network
  vpc peer-link

interface Ethernet1/5
  description vPC peer-keepalive link
  no switchport
  mtu 1500
  no shutdown
  ip address 10.20.0.0/31    # leaf1
  # leaf2 gets 10.20.0.1/31
```

### Design decisions for 6a

**Decision 1: Dedicated peer-keepalive link, not management network**

We use a separate physical link (Eth1/5) with a /31 subnet for
keepalive instead of the clab management network. Why? Management
network IPs are dynamic (clab assigns them at deploy time, may
shift across reboots). A dedicated link gives us stable IPs that
don't change.

This is also how production fabrics do it — peer-keepalive on a
dedicated cable means it works even if management connectivity
breaks.

**Decision 2: peer-switch + peer-gateway**

`peer-switch` tells STP "treat both leaves as one logical bridge"
(important for L2 stability). `peer-gateway` tells leaves to act
as the gateway for each other's anycast IPs (important for
asymmetric routing scenarios). These two settings together are
the modern Cisco standard for vPC.

**Decision 3: ipv6 nd synchronize + ip arp synchronize**

Without these, leaf1 and leaf2 build independent ARP/ND tables.
With them, they share. This ensures hosts always get a consistent
ARP reply regardless of which leaf they're reaching.

**Decision 4: delay restore 150**

When vPC re-forms after a failure, wait 150 seconds before
re-enabling member ports. Gives BGP/IGP time to converge first.
Prevents traffic black-holing during recovery.

### What 6a does NOT do

- No vPC member ports yet — host1 is still single-homed to leaf1
- No VXLAN VTEP coordination — both leaves still advertise their
  own loopback1 IP

### What you'll do (6a)

This session requires a **topology change** (new physical links
between leaves and to host1). That means the lab must be
**redeployed**, not switch.sh'd.

```bash
# Tear down current lab
containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup

# Slow boot the new topology (~15 min — last time you wait)
./scripts/deploy.sh 01-underlay

# Fast-switch through the curriculum to 6a
./scripts/switch.sh 06a-vpc-base
```

### Key test for 6a

```
ssh admin@clab-vxlan-evpn-leaf1
show vpc
```

Look for:

```
vPC domain id                     : 10
Peer status                       : peer adjacency formed ok
vPC keep-alive status             : peer is alive
Configuration consistency status  : success
```

If all four lines look like that, **6a is done**. The vPC base is
ready. Host bonding comes in 6b.

See `labs/06a-vpc-base/verify.md` for the full checklist.

### What we've foreshadowed for 6b

In `vlan 99`, peer-link allowed VLANs include 99. That's the L3VNI
carrier VLAN. Some Cisco gotchas around vPC + L3VNI require the
L3VNI VLAN to traverse the peer-link too. We've already configured
this — it'll matter in 6c.

---

## Part 2: Session 6b — vPC Member Port + Host Bond (coming)

This will add:

- vPC ID 10 on Ethernet1/3 of both leaves (the port facing host1)
- Port-channel10 on both leaves with `vpc 10` binding
- LACP active mode on the host port
- Linux LACP bond on host1 across eth1 and eth2

Host config will change — host1 gets `bond0` with eth1+eth2 as
members. host1's IP moves from eth1 to bond0.

Key test: host1 pings host2. Then shut Ethernet1/3 on leaf1 —
host1 should keep pinging via leaf2 alone.

## Part 3: Session 6c — vPC + VXLAN Integration (coming)

This will add the shared-VTEP configuration:

- `interface loopback1` gets a secondary IP `10.0.1.100/32` on
  both leaves
- NVE source moves to the secondary IP
- EVPN advertises host1's MAC via the shared VTEP

Key test: from leaf3 (if it existed) or via show output, see that
host1's Type-2 route originates from `10.0.1.100` (shared) rather
than `10.0.1.21` (leaf1-specific) or `10.0.1.22` (leaf2-specific).

This is the most subtle integration point in VXLAN-EVPN and where
Cisco docs are most ambiguous. Expect 6c to need iteration.

---

## What you should be able to explain after Session 6

1. What problem does vPC solve and what's the alternative?
2. Why does vPC need two separate detection links (peer-link AND
   peer-keepalive)?
3. What's "peer-gateway" and why is it on?
4. What's special about the VTEP in a vPC pair?
5. What happens if the peer-link fails but peer-keepalive is up?
6. What's the role of LACP in vPC vs static EtherChannel?

---

## Production patterns we're foreshadowing

- **vPC orphan ports**: ports on the vPC pair that aren't part of
  any vPC. Behavior is asymmetric — non-trivial to reason about.
  Real deployments minimize orphan ports.
- **vPC + first-hop redundancy (HSRP/VRRP)**: in non-anycast-
  gateway designs, vPC pairs run HSRP together. Anycast gateway
  obviates HSRP for VXLAN fabrics but the pattern still appears
  in mixed-traditional deployments.
- **vPC fabric peering** (newer Cisco "vPC Fabric Peering"): no
  physical peer-link, peer-state via fabric BGP. Modern but
  complex. We're using classic vPC because it teaches the model.

---

## Next

Session 7: refactor the underlay from OSPF to eBGP. Pure config
change, no topology change. The current OSPF underlay works fine
for our scale but eBGP is what real hyperscalers use because it
scales better. We'll switch to eBGP without losing vPC or VXLAN
functionality.
