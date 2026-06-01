# Session 6a: Break-It Exercises

## Exercise 1: Shut the peer-link, observe vPC state

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/4
shutdown
end
```

**Hypothesis**: peer-link goes down. Since vPC keepalive is still
alive (different physical link), vPC enters a special "isolated"
state where each leaf decides to keep operating independently.

**Verify**:
```
show vpc
```

Look for `Peer-link status: down` and what happens to the
operational state. In modern NX-OS, the secondary leaf typically
shuts its vPC member ports to avoid split-brain.

```
show interface Ethernet1/4
```

Should show admin down.

**Restore**:
```
configure terminal
interface Ethernet1/4
no shutdown
end
```

Wait ~30 sec for vPC to re-form. Re-check `show vpc`.

**Lesson**: Loss of peer-link is the most common vPC failure mode.
Modern Cisco vPC handles it gracefully via the keepalive heartbeat
— but only if keepalive is on a SEPARATE physical link (which is
why we designed it that way). If keepalive ran over the same link
as peer-link, both would fail together and we'd have split-brain.

## Exercise 2: Break the keepalive instead

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/5
shutdown
end
```

**Hypothesis**: keepalive fails. **But peer-link is still up.**
This is actually the safer failure mode — both leaves can still
see each other via peer-link, so they don't split-brain. NX-OS
should keep vPC functional but log warnings.

**Verify**:
```
show vpc
```

Should show: `vPC keep-alive status: peer is not alive` but
peer adjacency remains formed. Some Cisco docs call this a
"warning" state — vPC continues to operate but you've lost a
detection mechanism.

**Restore**:
```
configure terminal
interface Ethernet1/5
no shutdown
end
```

**Lesson**: The dual-failure-detection design (peer-link AND
keepalive separately) is what prevents split-brain. Either alone
can fail and the fabric survives. **Both failing simultaneously**
is the catastrophic scenario — and very unlikely on separate
physical links.

## Exercise 3: Mismatched vPC domain ID

What if leaf1 and leaf2 try to form vPC with different domain IDs?

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
no vpc domain 10
vpc domain 20
peer-keepalive destination 10.20.0.0 source 10.20.0.1 vrf default
role priority 2
end
```

**Hypothesis**: vPC won't form because domain IDs don't match. The
peer adjacency requires both ends to claim the same domain.

**Verify**:
```
show vpc
```

Expected: `Peer status: peer adjacency error` or similar.

```
show vpc consistency-parameters global
```

Should highlight domain ID mismatch.

**Restore**:
```
configure terminal
no vpc domain 20
vpc domain 10
peer-keepalive destination 10.20.0.0 source 10.20.0.1 vrf default
role priority 2
peer-switch
peer-gateway
ip arp synchronize
ipv6 nd synchronize
delay restore 150
end
```

(Re-add all the original vPC settings.)

**Lesson**: vPC domain ID is the cluster identity. Both peers must
agree. In production, automation usually templates this — but
manual config errors cause real outages.

## Exercise 4: Trunk VLAN inconsistency on the peer-link

Add a VLAN to leaf1 that doesn't exist on leaf2:

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
vlan 999
name Test-Mismatch
exit
interface port-channel100
switchport trunk allowed vlan add 999
end
```

**Hypothesis**: vPC consistency check fails — the peer-link's
allowed VLANs differ between leaves. NX-OS may mark certain VLANs
as "suspended" on the peer-link.

**Verify**:
```
show vpc consistency-parameters global
show vpc consistency-parameters interface port-channel100
```

Look for VLAN-list mismatches.

```
show vpc
```

May show `Per-vlan consistency status: failed` for VLAN 999.

**Restore**:
```
configure terminal
interface port-channel100
switchport trunk allowed vlan remove 999
no vlan 999
end
```

**Lesson**: vPC consistency checks catch real production misconfigs.
"VLAN added on one switch, forgot the other" is a classic outage
trigger. The consistency check is preventive.

## Skip if short on time

These break-it exercises probe vPC's failure modes — useful for
operators, less critical for first-pass understanding. Come back
when you want to deepen confidence in vPC's behavior under stress.
