# Session 6b: Verification — Host LACP Bond Through vPC

**What 6b achieves**: host1's two NICs (eth1, eth2) form an LACP
bond. Each NIC connects to a different leaf, but the two leaves
present themselves as a single logical peer via vPC. If one leaf
dies, the bond keeps working on the other.

## Pre-check: 6a state was good before applying 6b

Before deploying 6b, confirm 6a was working:

```
ssh admin@clab-vxlan-evpn-leaf1
show vpc
```

Expected: `Peer status: peer adjacency formed ok`. The Secondary IP
warning from 6a is benign and persists into 6b.

## Step 1: Apply 6b config

```bash
./scripts/switch.sh 06b-vpc-host-bond
```

Expected: ~10 sec, "Config OK on leaf1 (found: vpc 10)"

## Step 2: Set up host1's LACP bond

This is **new** for 6b. host1 needs a Linux bond0 across eth1
(to leaf1) and eth2 (to leaf2). Run this on the VM:

```bash
docker exec clab-vxlan-evpn-host1 sh -c '
  # Load bonding kernel module
  modprobe bonding 2>/dev/null || true

  # Bring slave interfaces down before bonding
  ip link set eth1 down 2>/dev/null || true
  ip link set eth2 down 2>/dev/null || true

  # Flush any IPs that were on the slaves
  ip addr flush dev eth1
  ip addr flush dev eth2

  # Create bond0 with LACP active mode, fast LACP timer
  ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast 2>/dev/null || true

  # Enslave eth1 and eth2 to bond0
  ip link set eth1 master bond0
  ip link set eth2 master bond0

  # Bring everything up
  ip link set eth1 up
  ip link set eth2 up
  ip link set bond0 up

  # Apply host1 IP on bond0 (not on slaves anymore)
  ip addr add 10.100.10.10/24 dev bond0
  ip route replace default via 10.100.10.1
'
```

host2 doesn't change — still single-homed on its existing eth1 in
Tenant-B with 10.200.10.10.

## Check 1: Linux bond is up

```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0
```

Expected (highlights):
```
Bonding Mode: IEEE 802.3ad Dynamic link aggregation
LACP rate: fast
Number of ports: 2
Actor Key: ...
Partner Key: ...    <-- non-zero means LACP negotiated with a peer
Partner Mac Address: <leaf1's port-channel MAC>

Slave Interface: eth1
MII Status: up
Aggregator ID: 1

Slave Interface: eth2
MII Status: up
Aggregator ID: 1   <-- Both slaves in same aggregator = working LACP
```

**The critical thing**: both slaves are in **the same** Aggregator ID.
If they're in different aggregators (Slave 1 in agg 1, Slave 2 in
agg 2), LACP couldn't negotiate them as a single bond — likely
because the leaves are advertising different LACP system IDs.

## Check 2: leaves see the LACP peer

On leaf1:

```
show lacp neighbor
```

Expected: a neighbor entry for Eth1/3, with the host's LACP system
ID and port:
```
Flags:  S - Device is sending Slow LACPDUs   F - Device is sending Fast LACPDUs
        A - Device is in Active mode         P - Device is in Passive mode

port-channel10 neighbors

Partner's information

          Partner               Partner                     Partner
Port      System ID             Port Number     Age         Flags
Eth1/3    32768,<host1-bond0-mac>  0x1            0       FA
```

Same on leaf2 for Eth1/6.

## Check 3: vPC member port is in "up" state

```
show vpc
```

Expected now (with vPC ID 10 added):

```
Number of vPCs configured         : 1
...

vPC status
---------------------------------------------------------------------------
Id      Port           Status Consistency Reason                Active vlans
--      ------------   ------ ----------- ----------------       ---------------
10      Po10           up     success     success                10
```

The `Status: up` for vPC 10 means the bond is forwarding traffic
on **both** leaves.

If status is `down`: the bond isn't fully formed yet, or LACP didn't
converge. Wait 30 sec and re-check.

If status is `up*` (with the asterisk): the local vPC port is down
but forwarding is happening via peer-link from the other leaf.

## Check 4: host1 → host2 still works (cross-tenant via leak)

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: succeeds. TTL might be 62 or 63 depending on which leaf
forwards (vPC distributes flows across both).

## Check 5: Both leaves can reach host1

This is the proof that the bond works on both sides.

Force traffic via leaf1 by ARPing host1 from leaf1's perspective:

```
show ip arp vrf Tenant-A 10.100.10.10
```

Expected: host1's MAC visible from leaf1.

Then on leaf2:

```
show ip arp vrf Tenant-A 10.100.10.10
```

Expected: also visible. The MAC may have been synced via vPC's
`ip arp synchronize` feature.

## Check 6: Bond forwards on BOTH slaves (the real vPC test)

In one terminal, start a continuous ping:

```bash
docker exec clab-vxlan-evpn-host1 ping 10.100.10.1
```

Leave it running. In another terminal, watch byte counts on host1:

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'cat /proc/net/dev | grep -E "eth1|eth2|bond0"'
```

Run that command several times. You should see:
- bond0 RX/TX bytes incrementing rapidly
- **One of eth1 or eth2** also incrementing (depending on LACP hash)

LACP doesn't typically split a single flow across slaves — it picks
one slave per (src, dst, port) tuple. For a single ping flow, only
one slave will carry it. That's expected.

To see both slaves working, run multiple parallel pings:

```bash
docker exec clab-vxlan-evpn-host1 sh -c '
  ping 10.100.10.1 > /dev/null 2>&1 &
  ping 10.200.10.10 > /dev/null 2>&1 &
  ping 10.100.20.1 > /dev/null 2>&1 &
'
```

(Multiple destinations create multiple hash buckets, increasing
the chance both slaves see traffic.)

After 30 seconds:

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'cat /proc/net/dev | grep -E "eth1|eth2"'
```

You should see BOTH eth1 and eth2 with non-trivial RX/TX bytes.
That confirms the bond is actively using both physical links.

Cleanup the background pings:
```bash
docker exec clab-vxlan-evpn-host1 sh -c 'pkill ping'
```

## Check 7: Failover test — kill leaf1's host port

This is the killer demo.

In one terminal:

```bash
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

(Leave running.)

In another terminal:

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/3
shutdown
end
```

**Expected**: the ping continues. You may see one or two dropped
packets during convergence (LACP detects loss of partner on eth1,
re-balances flows to eth2). Then traffic resumes via leaf2 only.

Verify on host1:

```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | grep -A2 "Slave Interface"
```

Expected: `eth1: MII Status: down`, `eth2: MII Status: up`.

**Restore**:

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/3
no shutdown
end
```

Wait ~30 sec for LACP to re-converge. host1's bond will use both
slaves again.

## Troubleshooting

### Bond shows partner_key = 0 or no partner

LACP isn't negotiating. Causes:
- vPC member port on the leaf isn't `up` (check `show vpc`)
- LACP rate mismatch — leaf is slow, host is fast (or vice versa)
- VLAN mismatch on the trunk

Fix: confirm leaf's port-channel10 has `channel-group 10 mode active`
and `vpc 10`. On the host, confirm `lacp_rate fast` in the bond
options.

### Different Aggregator IDs on each slave

The two slaves negotiated independent LACP partnerships rather than
one shared bond. Most common cause: vPC's `peer-switch` config
isn't active, so the two leaves advertise different LACP system IDs.

Fix: confirm `peer-switch` is in `vpc domain 10` on both leaves.
Then bounce the host bond:
```bash
docker exec clab-vxlan-evpn-host1 sh -c '
  ip link set bond0 down
  ip link set bond0 up
'
```

### "vpc 10" command rejected on the port-channel

NX-OS sometimes rejects `vpc 10` until the vPC peer adjacency is
fully formed and consistency-checked. If the cfg push hits this,
you'll see it in `scripts/_push.log`. Fix: wait 30 sec for vPC to
fully form, re-run `./scripts/switch.sh 06b-vpc-host-bond`.

## Summary

If Checks 1-7 pass, Session 6b is verified:
- LACP bond formed on host1 (both slaves in same aggregator)
- vPC 10 status is `up` with both leaves participating
- Traffic flows across both physical paths
- Killing one leaf's host port doesn't break connectivity

6b makes the fabric **server-side resilient**. The next session, 6c,
tackles the VTEP coordination issue — making sure EVPN advertises
host1 via a shared VTEP IP so remote leaves can load-balance
traffic to either leaf1 or leaf2.
