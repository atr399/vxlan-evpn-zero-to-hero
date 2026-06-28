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

## Bring-up

Three checkpointed sub-sessions, applied in order on the running lab
(Model A). The current base topology already includes the vPC wiring
(peer-link Eth1/4, keepalive Eth1/5, host1 dual-NIC) — if your running
lab was deployed from an older topology without these links, do a fresh
`./scripts/reset.sh 01-underlay` first, then re-chain 01→05b.

```bash
cd ~/vxlan-evpn-zero-to-hero

# 6a — vPC domain + peer-link + keepalive
./scripts/switch.sh 06a-vpc-base
# Verify 'peer adjacency formed ok'. The Sec-IP inconsistency warning
# is EXPECTED here.

# 6b — host LACP bond + vPC member port
./scripts/switch.sh 06b-vpc-host-bond
# switch.sh prints the host1 bond setup (sysfs method). Run it.
# EXPECTED RESULT: vPC 10 stays DOWN on consistency failure - that is
# the lesson of 6b, fixed in 6c.

# 6c — the keystone fix (shared VTEP secondary IP)
./scripts/switch.sh 06c-vpc-vxlan
# vPC comes up, NVE flips to VPC-VIP-Only, cross-tenant ping works.
```

## Topology (this session)

The dormant links from Session 1 finally light up. vPC detail view:

```
              spine1                  spine2
                |  \                  /  |
                |   +------+  +------+   |
                |          |  |          |
              leaf1 ===== peer-link ===== leaf2
                |   Eth1/4 (Po100) Eth1/4  |
                |   Eth1/5 keepalive Eth1/5|
                |   (10.20.0.0/31)         |
              Eth1/3                    Eth1/6
                 \                        /
                  \    LACP bond0       /
                   +----- host1 -------+
                    eth1          eth2
                    10.100.10.10/24 on bond0

   Shared VTEP (6c): lo1 secondary 10.0.1.100/32 on BOTH leaves
   -> EVPN advertises the vPC pair as ONE VTEP
```

| vPC element | Where |
|-------------|-------|
| Peer-link (Po100) | leaf1 Eth1/4 ↔ leaf2 Eth1/4 |
| Peer-keepalive | leaf1 Eth1/5 ↔ leaf2 Eth1/5, 10.20.0.0/31 |
| Host bond (vPC 10 / Po10) | leaf1 Eth1/3 + leaf2 Eth1/6 → host1 eth1+eth2 |
| Shared VTEP VIP | 10.0.1.100/32 secondary on lo1, both leaves |

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

> **Paste this exactly once, with NO inline comments.** When the
> `switch.sh` hint or this doc shows `# comments` inside the bond block,
> strip them before pasting into `docker exec ... sh -c '...'` — a `#`
> comment that contains a `)` (e.g. "set mode (Alpine quirk)") will
> break the single-quoted shell string with `syntax error near
> unexpected token ')'`. And if a paste errors partway, **do not blindly
> re-run it** — repeated half-runs thrash the links and can
> error-disable the leaf member port (see "Lab hygiene"). Fix the
> command, then run the clean block once:

```bash
docker exec clab-vxlan-evpn-host1 sh -c '
ip link set bond0 down 2>/dev/null
ip link delete bond0 2>/dev/null
ip link add bond0 type bond
echo 802.3ad > /sys/class/net/bond0/bonding/mode
echo fast > /sys/class/net/bond0/bonding/lacp_rate
echo 100 > /sys/class/net/bond0/bonding/miimon
ip link set eth1 down
ip link set eth2 down
ip addr flush dev eth1
ip addr flush dev eth2
ip link set eth1 master bond0
ip link set eth2 master bond0
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up
ip addr add 10.100.10.10/24 dev bond0
ip route replace default via 10.100.10.1
'
```

The sysfs approach is needed because Alpine's `ip link add bond0
type bond mode 802.3ad` doesn't reliably apply the mode parameter.

Verify the bond formed cleanly — **both slaves up and in the same
Aggregator ID** is the tell that LACP negotiated correctly end-to-end:

```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | grep -E "MII Status|Slave Interface|Aggregator ID"
# want: both eth1 and eth2 "up", both showing the SAME Aggregator ID
```

### What 6b reveals — the consistency failure

After applying 6b and bringing up the host bond, you'll see something
surprising:

```
show vpc
```
```
Configuration consistency status  : failed
Configuration inconsistency reason: Secondary IP address does not match
...
10    Po10    down*    success    success    -
```

The LACP bond is up on the host. The vPC peer adjacency is up
("peer adjacency formed ok", "peer is alive"). But the vPC member port
(Po10) refuses to forward. **Why?**

NX-OS treats the **vPC VTEP secondary IP** as a Type-1 consistency
parameter: both leaves of a vPC pair must present the *same* secondary
(VIP) IP on their VXLAN source loopback, because to the rest of the
fabric a vPC pair must look like **one** logical VTEP. At this point
neither leaf has that secondary IP configured, so the check reports
**"Secondary IP address does not match"** and holds the vPC member port
down.

> **The exact reason string matters.** The headline `show vpc` line
> says `Configuration consistency status : failed` with
> `Configuration inconsistency reason: Secondary IP address does not
> match`. That string is the precise, specific cause — not a generic
> "compat check." It tells you exactly what 6c must fix.

**The member-port reason cascades — don't be fooled by it.** Depending
on timing and whether the host bond is up yet, `show interface Eth1/3
brief` may report the member port down for *different* reasons as you
progress:

| Member-port "Reason" | What it actually means |
|----------------------|------------------------|
| `suspended (no LACP PDUs)` | Host hasn't started LACP yet — run the host bond setup. |
| `vpc peerlink is down` | The vPC *consistency* failure is holding the member down; the peer-link (Po100) is actually up. Misleading wording. |
| `Internal-Fail errDisable` | The port got **error-disabled** — usually from manual link thrashing, *not* part of the lesson. See "Lab hygiene" below. |

In **all** of these, the authoritative root cause is the `show vpc`
**consistency line** (`Secondary IP address does not match`), not the
per-port reason. Read `show vpc` first; treat the port reason as a
symptom.

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

## Quick review (flashcards)

Cover the right column.

### vPC fundamentals

| Question | Answer |
|----------|--------|
| What problem does vPC solve? | Lets a host **dual-home to two leaves** with one LACP bond, so either leaf or link can fail without dropping the host — while both leaves stay active (no STP blocking). |
| Peer-link vs peer-keepalive — why separate? | **Peer-link** (Po100) carries data + vPC control + sync; **peer-keepalive** is a separate L3 heartbeat used only to detect peer death and prevent dual-active. Separate links so a peer-link failure is distinguishable from a peer being down. |
| Why LACP (not static) for the host bond? | LACP actively negotiates and detects half-open links; the leaf only bundles a member when it sees the partner's LACPDUs (`suspended (no LACP PDUs)` until then). |
| Why does vPC + VXLAN need a shared VTEP IP? | The two leaves must look like **one logical VTEP** to the fabric. The shared secondary (VIP) IP on loopback1 makes EVPN advertise the pair as a single next-hop, so remote leaves don't see a host flapping between two VTEPs. |

### The 6b failure and 6c fix

| Question | Answer |
|----------|--------|
| At 6b, what's the exact vPC failure reason? | `Configuration consistency status: failed`, reason **"Secondary IP address does not match"** — the two leaves don't yet share the VTEP secondary IP. |
| Is the bond/LACP broken when 6b fails? | No — the bond can be fully up (both slaves up, same Aggregator ID) and LACP healthy. The vPC member stays **down purely on the consistency failure**. |
| What single line fixes it in 6c? | `ip address 10.0.1.100/32 secondary` on each leaf's loopback1 — the *same* secondary IP on both. |
| What does the NVE flip to after 6c? | **VPC-VIP-Only** mode — source-interface shows `primary: 10.0.1.21, secondary: 10.0.1.100`, and the pair advertises as one VTEP. |
| Member-port reason says "vpc peerlink is down" but Po100 is up — what's happening? | Misleading wording: the **consistency failure** is holding the member down, not the peer-link. Trust the `show vpc` consistency line, not the port reason. |

### Lab gotchas

| Question | Answer |
|----------|--------|
| Host-bond paste fails with `syntax error near unexpected token ')'` — why? | A `#` comment containing `)` inside the `sh -c '...'` string. Strip comments before pasting. |
| Member port stuck in `Internal-Fail errDisable` — cause and fix? | Caused by repeated link thrashing (re-running a failing paste). `shut`/`no shut` often won't clear it on N9000v; the reliable fix is `reset.sh` + clean re-chain. |
| 6b shows consistency **success** when the doc says it should fail — why? | Config pollution — 6c likely bled in from an earlier run. Reset and re-chain cleanly. |
| After a fresh chain, cross-tenant ping to host2 fails — first thing to check? | host2's IP. `switch.sh` doesn't re-run host setup; host2's Tenant-B address from Session 5a must be re-applied after a clean chain. |

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

## Lab hygiene — how to not waste an hour (learned the hard way)

This session is the most thrash-prone in the curriculum, because the
host-bond setup involves repeated link down/up and a multi-line paste.
Three failure modes and how to avoid them:

1. **Paste the host-bond block exactly once, with comments stripped.**
   A `#` comment containing a `)` breaks the `sh -c '...'` string
   (`syntax error near unexpected token ')'`). Worse, when a paste
   errors partway, the instinct is to re-run it — and repeated
   down/up/enslave cycles can drive the leaf's member port into
   **`Internal-Fail errDisable`**. Once a port is err-disabled, a plain
   `shutdown` / `no shutdown` often does **not** clear it on N9000v
   (you'll see "5 interface resets" and it bounces straight back to
   errDisable). Fix the command first, then run the clean block once.

2. **Partial config pushes pollute the lab and fake a "pass."** If 6c
   config ever bleeds into a 6b-state lab (e.g. from an earlier run that
   reached 6c), `show vpc` will show consistency **success** at 6b —
   hiding the very failure 6b is meant to teach. If 6b shows success
   when the doc says it should fail, suspect pollution, not a working
   lab.

3. **When in doubt, reset and re-chain — don't debug a dirty lab.** A
   polluted or err-disabled lab costs more time to untangle than a clean
   rebuild. The reliable recovery:
   ```bash
   ./scripts/reset.sh 01-underlay
   # wait for all n9kv (healthy), then re-chain cleanly to where you were:
   for s in 01-underlay 02-overlay 03-l2vni 04-anycast-gw \
            05a-tenant-b 05b-route-leak 06a-vpc-base 06b-vpc-host-bond; do
     ./scripts/switch.sh "$s"
   done
   ```
   On a clean chain, 6b shows the real failure — `Configuration
   inconsistency reason: Secondary IP address does not match` — and 6c
   resolves it to `success` with the member port coming up.

> **Host state carried from earlier sessions:** the `switch.sh` chain
> pushes *device* config but does **not** re-run host setup. host2 was
> moved to Tenant-B (`10.200.10.10`) back in **Session 5a** and *stays
> there* through 6a/6b/6c — the vPC sessions only reconfigure **host1's**
> bond. If you re-chain from scratch and skip 5a's host setup, host2 has
> no IP, and cross-tenant tests (host1 → `10.200.10.10`) will fail for a
> reason that has nothing to do with vPC. Re-apply host2's Session 5a
> setup after a fresh chain.

---

## Next

You've built dual-homed host attachment the production way: vPC with a
shared anycast VTEP, so a host can bond to two leaves and the fabric
sees one logical VTEP.

**To advance (Model A — no redeploy):**

```bash
./scripts/switch.sh 07-ebgp-underlay
```

Session 7 refactors the underlay from **OSPF to eBGP** — pure config
change, no topology change. The OSPF underlay works fine at our scale,
but eBGP is what hyperscalers use because it scales better (no
area-wide LSA flooding). We switch without losing vPC or VXLAN.

> **Expect a brief reachability blip** during the swap: the push removes
> OSPF and the single-AS iBGP, then builds per-device-ASN eBGP. For
> ~30–60s the underlay is mid-transition — don't debug inside that
> window; wait for eBGP to converge, then verify.
