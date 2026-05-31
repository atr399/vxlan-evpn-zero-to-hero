# Session 3: Verification

After deploy + host IP configuration, run through these checks.
Order matters here — verify the control plane before testing the data
plane, because if Type-2 routes aren't flowing, ping won't work.

## Check 0: Hosts have IPs (must do this first)

If you skipped the manual host configuration, ping will fail for an
uninteresting reason. From the VM shell:

```bash
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host2 ip addr show eth1
```

You should see `inet 10.100.10.10/24` and `inet 10.100.10.11/24`
respectively. If not, go back to the doc and run the host config.

## Check 1: Features enabled on leaves

On leaf1:

```
show feature | include "vn-segment|nv overlay|interface-vlan"
```

Expected:

```
interface-vlan         1          enabled
nv_overlay             1          enabled
vn-segment-vlan-based  1          enabled
```

Also confirm `nv overlay evpn` is in running-config:

```
show running-config | include "nv overlay"
```

You should see both `feature nv overlay` and `nv overlay evpn`.

## Check 2: VLAN-to-VNI mapping

```
show vlan id 10
show vlan id 10 vn-segment
```

VLAN 10 should be active with `vn-segment 10010` mapped. If the
vn-segment column is empty, the mapping didn't apply — usually because
`feature vn-segment-vlan-based` wasn't enabled when the config was
pushed.

## Check 3: NVE interface is up and operational

```
show interface nve1
```

Look for:

```
nve1 is up
admin state is up, ...
NVE Interface state is Up
Source-Interface: loopback1 (primary: 10.0.1.21, secondary: 0.0.0.0)
...
Host Reachability Mode: control-plane
```

The phrase **"Host Reachability Mode: control-plane"** is what
confirms BGP-EVPN is driving MAC learning (not flood-and-learn). If
it says `data-plane`, you're in flood-and-learn mode — check that
`host-reachability protocol bgp` is configured under `interface nve1`.

## Check 4: NVE VNI status

```
show nve vni
```

Expected:

```
Interface VNI    Multicast-group State Mode Type [BD/VRF]   Flags
--------- ------ --------------- ----- ---- -----------    -----
nve1      10010  UnicastBGP      Up    CP   L2 [10]
```

- **VNI 10010** is configured
- **State Up** means it's operational
- **CP** = Control Plane (BGP-EVPN), correct
- **L2 [10]** = Layer 2 VNI mapped to VLAN 10
- **UnicastBGP** = ingress replication, BGP-driven

Same output expected on leaf2.

## Check 5: NVE peer relationship

```
show nve peers
```

Expected:

```
Interface Peer-IP          State LearnType Uptime    Router-Mac
--------- ---------------  ----- --------- --------  -----------------
nve1      10.0.1.22        Up    CP        00:0X:XX  n/a
```

That `Peer-IP 10.0.1.22` is leaf2's VTEP loopback. **State Up** means
the VXLAN tunnel from leaf1's perspective is operational. **LearnType
CP** means the peer was discovered through BGP-EVPN (Type-3 route),
not from data-plane flooding.

If `show nve peers` is empty, the Type-3 routes aren't being exchanged
or the leaves aren't agreeing on RT values. Check `show bgp l2vpn evpn`
in the next check.

## Check 6: Type-3 routes (peer discovery)

Type-3 EVPN routes are the "I'm a VTEP, here's my IP" announcements.
You should see one Type-3 from your local leaf and one from the remote
leaf:

```
show bgp l2vpn evpn route-type 3
```

Expected — two route lines, one with each leaf's VTEP IP. Format:

```
Route Distinguisher: 10.0.0.21:32777    (L2VNI 10010)
*>l[3]:[0]:[32]:[10.0.1.21]/88
                      10.0.1.21                                 100      32768 i

Route Distinguisher: 10.0.0.22:32777    (L2VNI 10010)
*>i[3]:[0]:[32]:[10.0.1.22]/88
                      10.0.1.22                                 100          0 i
```

The `[3]:[0]:[32]:[10.0.1.21]/88` is an EVPN route key — Type-3 (Inclusive
Multicast Route), Ethernet Tag 0, 32-bit IP, originator's IP.

The two leaves now know about each other as VTEPs interested in
VNI 10010.

## Check 7: Type-2 routes (MAC/IP advertisements) — initially empty

```
show bgp l2vpn evpn route-type 2
```

**Before** any host pings, this might be empty or have only static
entries. **The Type-2 routes show up when hosts start ARPing or
sending traffic.** That's the next check.

## Check 8: Trigger MAC learning and watch Type-2 appear

Send a ping to populate the host MAC tables on the leaves:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11
```

If this succeeds: **Session 3 is working end-to-end.** Three
successful pings means VXLAN encap/decap, BGP-EVPN MAC learning, and
the underlay all work together.

If it times out, run the next check to find the gap.

Re-run on leaf1:

```
show bgp l2vpn evpn route-type 2
```

You should now see Type-2 routes for both host1's MAC (originated
locally) and host2's MAC (learned from leaf2 via the spine RRs).

```
show l2route evpn mac all
```

This is a clean view of where each MAC lives:

```
Topology Mac Address    Prod  Flags         Seq No     Next-Hops
-------  -------------- ----- ------------- ---------- ----------
10       aaaa.bbbb.cc01 Local                          Eth1/3
10       aaaa.bbbb.cc02 BGP   SplRcv                   10.0.1.22
```

The exact MACs depend on what your hosts use, but the pattern is:
- One MAC learned `Local` via Eth1/3 (your own host)
- One MAC learned via `BGP` with next-hop = remote VTEP (the other host)

## Check 9: Compare standard MAC table to EVPN MAC table

```
show mac address-table dynamic
```

You should see two MAC entries on VLAN 10 — one via `Eth1/3` (local
host) and one via `nve1(10.0.1.22)` (remote host, reached over VXLAN
tunnel to leaf2's VTEP).

That `nve1(10.0.1.22)` notation is how NX-OS represents "this MAC is
reachable via my VXLAN tunnel to remote VTEP 10.0.1.22." This is the
moment where Cisco's standard switching commands and the new
VXLAN-EVPN constructs unify into a single forwarding table.

## Check 10: End-to-end ping with timing

```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.10.11
```

Expected: 5 replies, latency in milliseconds (probably ~1-5ms).

The first packet might be slightly slower because ARP has to resolve
first (which itself rides EVPN). Subsequent packets are pure data
plane forwarding.

## Summary of what success looks like

- Features enabled, VLAN-to-VNI mapping in place
- `show nve peers` shows the remote VTEP, learned via CP
- `show bgp l2vpn evpn route-type 3` has two routes (one per VTEP)
- After triggering traffic, `show bgp l2vpn evpn route-type 2` shows
  MAC routes
- `show mac address-table dynamic` shows the remote MAC via
  `nve1(10.0.1.22)`
- host1 can ping host2

If all 10 checks pass, you have a working L2VNI. Take a moment — this
is the first session where you've built something visible that wasn't
possible before. Hosts on different leaves think they're on the same
LAN.
