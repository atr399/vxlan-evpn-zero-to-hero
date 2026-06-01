# Session 6: vPC (Multi-Chassis LAG) + VXLAN Integration

**Prerequisites**: Session 5b working. Topology change required —
this session and beyond use the **expanded topology** with peer-link
and dual-homed host.

**Goal**: Dual-home host1 across leaf1 and leaf2 so the host has
two physical NICs in an LACP bond. The two leaves act as one
logical switch from host1's perspective. Add a shared VTEP IP so
EVPN advertises host1 from the vPC pair as a unit, not from
individual leaves.

**Lab folders**: `labs/06a-vpc-base/`, `labs/06b-vpc-host-bond/`,
`labs/06c-vpc-vxlan/`

**Estimated time**: 60 minutes total. 6a alone is ~20 min; 6b
~20 min; 6c ~15 min plus the failover demo.

---

## Mental model

In a real data center, every server has **two** physical NICs.
Each NIC connects to a different leaf. The two NICs form an LACP
bond on the server. From the server's perspective: one logical
link, double the bandwidth, full leaf-failure protection.

The challenge: **two physical switches need to pretend to be one
switch.** The host bond sees consistent LACP behavior from both
leaves; the EVPN fabric sees a single VTEP for traffic destined
to the host.

Three core mechanisms:

| Mechanism | Purpose |
|-----------|---------|
| **Peer-link** | Bulk traffic link between leaves. Carries data + vPC control. |
| **Peer-keepalive** | Out-of-band heartbeat. Detects "is my peer alive?" |
| **Shared VTEP IP** | Loopback1 secondary IP, identical on both leaves. EVPN advertises via this shared IP so the vPC pair looks like one VTEP. |

The third mechanism — shared VTEP — is what makes vPC + VXLAN
actually work. Without it, EVPN consistency checks fail and vPC
member ports never come up.

---

## Why three checkpoints

vPC + VXLAN is the densest config in the curriculum. Real Cisco
deployment guides break it into multiple chapters. We do the same:

```
6a: vPC base (peer-link, peer-keepalive, vPC domain)
    → Checkpoint: vPC peer adjacency formed; no host bonded yet

6b: vPC + host LACP bond (vPC member port + Linux bonding)
    → Checkpoint: host1 has working LACP bond — BUT vPC member
                  port stays down because of consistency failure

6c: vPC + VXLAN shared VTEP (the keystone fix)
    → Checkpoint: vPC consistency passes, member ports come up,
                  EVPN advertises via shared VTEP, failover works
```

Each session is independently deployable. Checkpoints help isolate
bugs.

---

## Part 1: Session 6a — vPC Base

### What we're adding (on top of Session 5b)

**On both leaves**:

```
feature vpc
feature lacp

vpc domain 10
  peer-switch
  role priority 1                                    # leaf2 gets priority 2
  peer-keepalive destination 10.20.0.1 source 10.20.0.0 vrf default
  delay restore 150
  peer-gateway
  ipv6 nd synchronize
  ip arp synchronize

interface Ethernet1/4
  switchport
  switchport mode trunk
  switchport trunk allowed vlan 1,10,20,30,40,98,99
  channel-group 100 mode active

interface port-channel100
  switchport mode trunk
  switchport trunk allowed vlan 1,10,20,30,40,98,99
  spanning-tree port type network
  vpc peer-link

interface Ethernet1/5
  no switchport
  mtu 1500
  ip address 10.20.0.0/31      # 10.20.0.1/31 on leaf2
```

### Design decisions for 6a

**Decision 1: Dedicated peer-keepalive link, not management network**

We use a separate physical link (Eth1/5) for peer-keepalive instead
of the clab management network. This matches production practice
and gives us stable IPs that don't shift across deploys.

**Decision 2: peer-switch + peer-gateway**

`peer-switch` makes both leaves advertise the same LACP system ID —
essential for the host bond to treat them as one peer.
`peer-gateway` lets each leaf route for the other's anycast IPs —
important for asymmetric traffic flows.

**Decision 3: delay restore 150**

When vPC re-forms after a failure, wait 150 seconds before
re-enabling member ports. Gives BGP/IGP time to converge first.
Prevents traffic black-holing during recovery.

### Key test for 6a

```
show vpc
```

Look for: `Peer status: peer adjacency formed ok`. The
"Configuration inconsistency reason: Secondary IP address does
not match" warning is **expected** here — we'll fix it in 6c.

---

## Part 2: Session 6b — Host LACP Bond

### What we're adding (on top of 6a)

**On both leaves**:

```
interface Ethernet1/3         # was access vlan 10 in 6a
  switchport
  switchport mode trunk
  switchport trunk native vlan 10
  switchport trunk allowed vlan 10
  channel-group 10 mode active   # joins LACP

interface port-channel10
  switchport mode trunk
  switchport trunk native vlan 10
  switchport trunk allowed vlan 10
  spanning-tree port type edge trunk
  mtu 9216
  vpc 10                          # binds to vPC ID 10
```

(Same config on both leaves — leaf2 uses Eth1/6 instead of Eth1/3
because that's the physical port to host1's second NIC.)

**On host1** (Linux bonding via sysfs):

```bash
# Create bond0 in LACP mode
ip link add bond0 type bond
echo 802.3ad > /sys/class/net/bond0/bonding/mode
echo fast > /sys/class/net/bond0/bonding/lacp_rate
echo 100 > /sys/class/net/bond0/bonding/miimon

# Enslave eth1 and eth2 to bond0
ip link set eth1 master bond0
ip link set eth2 master bond0

# Bring up + assign IP to bond0
ip link set bond0 up
ip addr add 10.100.10.10/24 dev bond0
ip route replace default via 10.100.10.1
```

The sysfs approach is needed because Alpine's `ip link add bond0
type bond mode 802.3ad` doesn't reliably apply the mode parameter.

### What 6b reveals — the consistency failure

After applying 6b, you'll see something surprising:

```
show vpc

vPC 10: status down*
Reason: Global compat check failed
```

The LACP bond is up on the host. The vPC peer adjacency is up.
But the vPC member port (Po10) refuses to forward. **Why?**

Cisco's NX-OS treats certain vPC consistency checks as hard
prerequisites: if **any global parameter mismatches** between the
two leaves, no vPC member ports come up.

Running:
```
show vpc consistency-parameters global
```

...reveals: `Nve1: Sec IP: 0.0.0.0` on both leaves. The check
"do you have a matching vPC VIP?" returns false because **neither**
leaf has a VIP. NX-OS interprets this as a failure rather than
"both same" (a behavior quirk in 10.5.x).

**This is 6c's job to fix.**

---

## Part 3: Session 6c — Shared VTEP for VXLAN

### The keystone fix

One config line on each leaf:

```
interface loopback1
  ip address 10.0.1.100/32 secondary   # same IP on both leaves
```

### Why this single line matters

When NX-OS sees a matching secondary IP on loopback1 across both
vPC peers:

1. **vPC consistency check passes**. The previously-failing global
   compat check now succeeds — member ports come up.

2. **NVE switches to "VPC-VIP-Only" mode**. Instead of advertising
   EVPN routes with each leaf's primary loopback IP as next-hop,
   NVE uses the shared secondary (10.0.1.100). Remote leaves see
   "the vPC pair" as one VTEP.

3. **Load balancing becomes possible**. Remote leaves can choose
   either leaf1 or leaf2 as the path for traffic to the shared
   VTEP — both are equivalent in OSPF.

4. **Chassis failover becomes graceful**. If leaf1 dies, leaf2
   still advertises 10.0.1.100. Remote leaves see the underlay
   path shift (leaf1→spine no longer reachable), but the EVPN
   overlay doesn't change. Traffic continues to flow.

You can verify this with:
```
show nve interface nve1 detail
```

Look for:
```
VPC Capability: VPC-VIP-Only [notified]
Source-Interface: loopback1 (primary: 10.0.1.21, secondary: 10.0.1.100)
```

`[notified]` confirms NX-OS has flipped to using the VIP for
advertisements.

```
show bgp l2vpn evpn route-type 2
```

Host1's MAC entries should now show next-hop `10.0.1.100`, not
`10.0.1.21`. Look for `SOO:10.0.1.100:0` in the extcommunity —
the Site-of-Origin marking telling remote leaves "this came from
the vPC pair."

### The killer demonstration

```bash
# Continuous ping
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

Leave running. In another terminal:

```bash
docker stop clab-vxlan-evpn-leaf1
```

Ping continues with 1-2 packet loss during LACP reconvergence,
then resumes via leaf2 alone. **Host has no idea what happened.**
Same MAC, same IP, same gateway. From host1's perspective, just
one of its NICs went down — the bond keeps working.

This is the entire reason vPC exists. Production fabrics rely on
this for chassis maintenance, hardware failures, software upgrades.

---

## What you should be able to explain after Session 6

1. What problem does vPC solve and what's the alternative?
2. Why are peer-link and peer-keepalive on separate physical links?
3. What's the role of LACP in vPC vs. static EtherChannel?
4. Why does vPC + VXLAN need a shared VTEP IP?
5. What happens to EVPN advertisements when a leaf dies in a vPC
   pair?
6. Why does the bond use `lacp_rate fast`?

---

## Production patterns we're foreshadowing

- **vPC orphan ports**: ports on the vPC pair that aren't part of
  any vPC. Behavior is asymmetric — non-trivial to reason about.
  Real deployments minimize orphan ports.
- **vPC fabric peering** (newer Cisco): no physical peer-link,
  peer-state via fabric BGP. Modern but complex. We're using
  classic vPC because it teaches the model.
- **Stretched vPC**: vPC pair across geographically separated
  data centers via DCI. Cisco generally advises against; we won't
  cover.

---

## Lessons from the build

Real things we learned while building this session:

1. **The "Sec IP" warning in 6a wasn't benign.** It became blocking
   the moment we added a vPC member port in 6b. Cisco's docs treat
   "this warning persists across config" as a non-issue, but
   it's the first thing that breaks when you actually try to use
   vPC. Including the secondary IP from the start prevents this.

2. **Alpine's `ip link add bond0 type bond mode 802.3ad` doesn't
   reliably apply the mode parameter.** Use sysfs: `echo 802.3ad
   > /sys/class/net/bond0/bonding/mode`. Native sysfs is more
   reliable in containers.

3. **The vPC + VXLAN integration is one line of config.** Just
   `ip address 10.0.1.100/32 secondary` on each leaf's loopback1.
   But that one line is the difference between "vPC works" and
   "vPC mysteriously refuses to forward."

---

## Next

Session 7: refactor the underlay from OSPF to eBGP. Pure config
change, no topology change. The current OSPF underlay works fine
for our scale but eBGP is what real hyperscalers use because it
scales better. We'll switch to eBGP without losing vPC or VXLAN
functionality.
