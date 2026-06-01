# Session 6a: Verification — vPC Base (Peer Adjacency Up)

**What 6a achieves**: Two leaves form a vPC domain. They can talk
to each other via the peer-link and detect each other's health via
peer-keepalive. **No host bond yet — that comes in 6b.**

## Pre-check: lab is the new topology

```bash
docker ps
```

Expect 6 containers. Check that leaf1 and leaf2 have additional
links visible:

```bash
docker exec clab-vxlan-evpn-leaf1 cat /etc/os-release 2>/dev/null | head -1 || echo "(can't inspect container)"
```

Run from the VM (not inside containers):

```bash
docker network inspect clab --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}} {{println}}{{end}}'
```

Just confirms containers are wired. The new physical links (eth4,
eth5, eth6) won't show in this output — they're internal clab
veth pairs.

## Check 1: Peer-link interface is up

On leaf1:

```
ssh admin@clab-vxlan-evpn-leaf1
```

```
show interface port-channel100
```

Expected: `port-channel100 is up`, Members: `Ethernet1/4`.

```
show interface Ethernet1/4
```

Expected: physical link up, MTU 9216, in port-channel 100.

If Eth1/4 is **down**: clab didn't create the new link (or the
topology file wasn't applied). Check:

```bash
containerlab inspect -t labs/01-underlay/topology.clab.yml
```

Should show all 6 containers running.

## Check 2: Peer-keepalive interface is up and reachable

```
show interface Ethernet1/5
```

Expected: up, IP `10.20.0.0/31` (leaf1) or `10.20.0.1/31` (leaf2).

From leaf1:

```
ping 10.20.0.1
```

Expected: replies. If no replies, the keepalive link is broken
and vPC won't form.

## Check 3: vPC peer adjacency

The big one. On leaf1:

```
show vpc
```

Expected output snippet:

```
Legend:
                (*) - local vPC is down, forwarding via vPC peer-link

vPC domain id                     : 10
Peer status                       : peer adjacency formed ok
vPC keep-alive status             : peer is alive
Configuration consistency status  : success
Per-vlan consistency status       : success
Type-2 consistency status         : success
vPC role                          : primary
Number of vPCs configured         : 0
Peer Gateway                      : Enabled
Dual-active excluded VLANs        : -
Graceful Consistency Check        : Enabled
Auto-recovery status              : Disabled
Delay-restore status              : Timer is off.(timeout = 150s)
Delay-restore SVI status          : Timer is off.(timeout = 10s)
Operational Layer3 Peer-router    : Disabled

vPC Peer-link status
---------------------------------------------------------------------
id    Port   Status Active vlans
--    ----   ------ --------------------------------------------------
1     Po100  up     1,10,20,30,40,98-99
```

The **key lines**:
- `Peer status: peer adjacency formed ok`
- `vPC keep-alive status: peer is alive`
- `Configuration consistency status: success`

If any say `error` or `failed`, see Troubleshooting below.

## Check 4: vPC role assignment

On leaf1:

```
show vpc role
```

Expected:
```
vPC role: primary
```

On leaf2 (in another SSH session):

```
show vpc role
```

Expected:
```
vPC role: secondary
```

The roles are determined by `role priority` in the vPC domain
config (lower priority = primary; we set leaf1=1, leaf2=2).

## Check 5: Underlay & overlay still work

vPC adds plumbing but shouldn't disturb Sessions 1-5 functionality.
Confirm:

```
show ip ospf neighbors
```

Should still show 2 FULL neighbors (the spines).

```
show bgp l2vpn evpn summary
```

Should still show 2 BGP sessions Established with the spines.

```
show nve vni
```

Should still show all 6 VNIs (10010, 10020, 10030, 10040, 50001,
50002) up.

## Check 6: Cross-tenant ping still works

Make sure Session 5b's route leak still operates:

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: succeeds, TTL=62.

If this fails after Session 6a deploy, vPC added some interference
— likely peer-gateway is shifting traffic in unexpected ways. We'd
debug.

## Troubleshooting

### "Peer adjacency: error" or "vPC keep-alive: peer is not alive"

Most likely: the peer-keepalive link isn't passing traffic. Test
directly:

```
ssh admin@clab-vxlan-evpn-leaf1
ping 10.20.0.1
```

If this fails, the Eth1/5 link is broken or down on the other side.
Check `show interface Ethernet1/5` on both leaves.

### "Configuration consistency status: failed"

The two leaves' vPC configs disagree. Common causes:
- Different `vlan` configs (one leaf has VLAN 10, the other
  doesn't)
- Different MTU on peer-link
- Different `feature` set

```
show vpc consistency-parameters global
```

Tells you exactly which parameters differ.

### "Per-vlan consistency status: failed"

VLAN-specific config differs (e.g., VLAN 10 exists on leaf1 but not
leaf2). Run on both leaves:

```
show vlan brief
```

Compare. The cfg files SHOULD have identical VLAN definitions, but
verify.

### vPC stays in "init"

The peer-link itself isn't fully up. Check:

```
show interface port-channel100
show interface Ethernet1/4
```

If Eth1/4 reports "no link," the new clab link didn't materialize.
Confirm clab actually has 6 links by running:

```bash
docker exec clab-vxlan-evpn-leaf1 ip link show
```

Should see 6+ interfaces (eth0 mgmt, eth1-eth5 lab).

## Summary

If Checks 1-6 pass, Session 6a is verified:
- Peer-link operational on port-channel100
- Peer-keepalive heartbeating between leaves
- vPC domain formed with leaf1=primary, leaf2=secondary
- All Sessions 1-5 functionality preserved

**What 6a does NOT yet do**: dual-home host1. There's no vPC
member port facing the host yet. host1 is still single-homed to
leaf1. That's 6b's job.

Move to 6b when ready: `./scripts/switch.sh 06b-vpc-host-bond`
(coming next).
