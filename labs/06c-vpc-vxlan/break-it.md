# Session 6c: Break-It Exercises

## Exercise 1: Remove the secondary IP — watch vPC regress

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface loopback1
no ip address 10.0.1.100/32 secondary
end
```

**Hypothesis**: NVE will detect the change, vPC consistency will
fail, vPC member port (Po10) will go down. host1's bond will
remain LACP-up on the host side, but traffic will stop flowing
because the leaves no longer have an active vPC port-channel.

**Verify**:
```
show vpc
```

Within ~10 sec:
- `Configuration consistency status: failed`
- `vPC 10: status down`

```
show nve interface nve1 detail
```

VPC Capability should change from `VPC-VIP-Only [notified]` to
`None`.

From the VM:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10
```

Expected: traffic fails.

**Restore**:
```
configure terminal
interface loopback1
ip address 10.0.1.100/32 secondary
end
```

Wait ~30 sec for vPC to re-form. host1 traffic resumes.

**Lesson**: The single line `ip address 10.0.1.100/32 secondary`
is what makes vPC + VXLAN work. Without it, the lab has a vPC
peer adjacency but no functional member ports. **This line is the
keystone of the entire vPC + EVPN integration.**

## Exercise 2: Mismatched secondary IPs

What if leaf1 says 10.0.1.100 but leaf2 says 10.0.1.200?

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface loopback1
no ip address 10.0.1.100/32 secondary
ip address 10.0.1.200/32 secondary
end
```

**Hypothesis**: Each leaf advertises a different VIP. NVE detects
the mismatch and either refuses to use either, or reports
consistency failure.

**Verify**:
```
show vpc
```

Expected: Configuration inconsistency reason: Secondary IP address
does not match.

```
show nve interface nve1 detail
```

VPC Capability may still show `VPC-VIP-Only` but the secondary IP
shown will be different on each leaf.

**Restore**:
```
configure terminal
interface loopback1
no ip address 10.0.1.200/32 secondary
ip address 10.0.1.100/32 secondary
end
```

**Lesson**: vPC VIP must match exactly between the two leaves. In
production, this is enforced via automation/templating — but a
typo can silently break the fabric in subtle ways. The consistency
check is your friend.

## Exercise 3: Full failover — destroy leaf1 mid-flow

The production-essential test.

In one terminal:
```bash
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

In another terminal:
```bash
docker stop clab-vxlan-evpn-leaf1
```

**Hypothesis**: The ping continues through leaf2 alone, with brief
loss during LACP reconvergence.

**Verify on host1**:
```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | grep -E "MII|Slave"
```

Should show eth1: MII Status: down, eth2: MII Status: up.

**Restore**:
```bash
docker start clab-vxlan-evpn-leaf1
```

Wait ~60-90 sec for leaf1 to come back. NX-OS will reload its
config from startup-config, vPC re-forms, EVPN re-advertises via
the shared VTEP.

If leaf1's config didn't persist (rare), reapply:
```bash
./scripts/switch.sh 06c-vpc-vxlan
```

**Lesson**: This is the entire reason vPC exists. **One chassis
failure, zero customer impact** (modulo a brief LACP reconvergence
window). Production fabrics rely on this for maintenance windows,
hardware failures, and software upgrades.

## Exercise 4 (optional): Compare encapsulation pre- and post-vPC

Capture traffic during the failover to see the encap shift.

```bash
./scripts/capture.sh leaf2 eth1 06c-vpc-failover 'udp port 4789'
```

In another terminal:
```bash
docker exec clab-vxlan-evpn-host1 ping 10.200.10.10
```

Then stop leaf1:
```bash
docker stop clab-vxlan-evpn-leaf1
```

Wait 30 sec, then start it again.

Examine the pcap. Look at:
- Outer source IP on captured packets — should be 10.0.1.100
  (shared VTEP) throughout, not changing as leaf1 goes down/up
- Brief LACP control frames during failover

**Lesson**: From the remote leaf's perspective (where we captured),
NOTHING about the VTEP changed during failover. The same shared
VTEP 10.0.1.100 advertised the same routes. Only the underlay path
to that VTEP shifted (was going to leaf1, now going to leaf2). The
VXLAN overlay was insulated from the chassis failure.

This is the **conceptual win** of the shared VTEP: the overlay
control plane doesn't even know a leaf died.

## Skip if short on time

Exercise 3 (full leaf failover) is the most important. It's the
production scenario every operator needs to be confident with.
The others probe details that are mostly relevant during initial
deployment.
