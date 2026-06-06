# Session 9: Break-It Exercises

## Exercise 1: Shut Eth1/7 — fabric loses external connectivity

```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
interface Ethernet1/7
shutdown
end
```

**Hypothesis**: eBGP session drops. External route withdrawn from
Tenant-A. EVPN Type-5 withdrawn from fabric. ALL leaves lose
reachability to 203.0.113.0/24.

**Verify** from any host:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
```
Expected: 100% loss.

```
show ip route 203.0.113.0/24 vrf Tenant-A
```
Expected: route not found.

```
show bgp l2vpn evpn route-type 5
```
Expected: 203.0.113.0/24 entry gone.

**Restore**:
```
configure terminal
interface Ethernet1/7
no shutdown
end
```

Wait ~15 sec for eBGP to re-establish and Type-5 to repropagate.

**Lesson**: Single-attached L3Out is a SPOF for external
connectivity. Real production deploys dual-attached L3Out — two
"border leaves" each running eBGP to (separate) external routers,
for redundancy.

## Exercise 2: Withdraw the route on extrouter

```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "
configure terminal
router bgp 65100
 address-family ipv4 unicast
  no network 203.0.113.0/24
 exit-address-family
end
"
```

**Hypothesis**: extrouter stops advertising the prefix. eBGP
withdraws. Fabric loses reachability to 203.0.113.0/24.

**Verify**:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
```
Expected: 100% loss.

```
ssh admin@clab-vxlan-evpn-leaf1
show ip route 203.0.113.0/24 vrf Tenant-A
```
Expected: not found.

**Restore**:
```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "
configure terminal
router bgp 65100
 address-family ipv4 unicast
  network 203.0.113.0/24
 exit-address-family
end
"
```

**Lesson**: The fabric depends on external advertisements. If the
external router misconfigures, the fabric loses external routes
gracefully — no traffic blackhole, no broken state. eBGP's
withdraw semantics handle this cleanly.

## Exercise 3: BGP timer mismatch

Default eBGP timers (keepalive 60s, hold 180s) are slow for data
center recovery. Let's see what happens during a failure.

Set fast timers on leaf1 only:
```
ssh admin@clab-vxlan-evpn-leaf1
configure terminal
router bgp 65000
  vrf Tenant-A
    neighbor 192.0.2.1
      timers 5 15
end
```

Wait 30 sec for the new timers to take effect (BGP renegotiates).

Now disable extrouter's BGP without doing a graceful shutdown:
```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "
configure terminal
router bgp 65100
 neighbor 192.0.2.0 shutdown
end
"
```

**Hypothesis**: With fast timers (5 sec keepalive, 15 sec hold),
leaf1 detects the dead neighbor in ~15 sec. With default timers,
it would take ~180 sec.

**Verify** the timing yourself:
```
show bgp vrf Tenant-A ipv4 unicast summary
```

Within ~15 sec, neighbor should show State `Active` or `Idle`.

**Restore**:
```bash
docker exec clab-vxlan-evpn-extrouter vtysh -c "
configure terminal
router bgp 65100
 no neighbor 192.0.2.0 shutdown
end
"
```

Set timers back to default on leaf1:
```
configure terminal
router bgp 65000
  vrf Tenant-A
    neighbor 192.0.2.1
      timers 60 180
end
```

**Lesson**: Default BGP timers are too slow for data center
convergence. Production uses one of:
- Fast BGP timers (5/15 like we just did) — works but BGP CPU intensive
- BFD with BGP — sub-second detection, less CPU. **Recommended**.
- Both: BFD for detection, BGP timers as backup

We didn't add BFD in this curriculum. It's a single-knob addition
on each neighbor (`neighbor X.X.X.X bfd`).

## Exercise 4: AS-path manipulation

What if extrouter is in a "weird" AS that causes loops? Let's
test what happens when we mess with the AS-path.

On leaf1:
```
configure terminal
route-map BLOCK_FABRIC_BACK deny 10
  match as-path 1
ip as-path access-list 1 permit "_65000_"
end
configure terminal
router bgp 65000
  vrf Tenant-A
    neighbor 192.0.2.1
      address-family ipv4 unicast
        route-map BLOCK_FABRIC_BACK in
end
clear ip bgp 192.0.2.1 soft in
```

This blocks any route received from extrouter that contains
65000 in its AS-path (a route that originally came from our fabric
and looped back).

**Hypothesis**: Normal operation unaffected. But if extrouter were
to advertise back our prefix (loop), we'd reject it.

**Verify**: normal connectivity should still work:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
```

**Restore**:
```
configure terminal
router bgp 65000
  vrf Tenant-A
    neighbor 192.0.2.1
      address-family ipv4 unicast
        no route-map BLOCK_FABRIC_BACK in
end
configure terminal
no ip as-path access-list 1
no route-map BLOCK_FABRIC_BACK
end
```

**Lesson**: Production L3Out always has inbound and outbound
policy. Defaults are dangerous — never let an L3Out neighbor
advertise arbitrary routes into your fabric.

Common policies:
- Inbound: deny default route (unless you want it), deny private
  ASNs, deny our own AS, prefix-list of expected routes
- Outbound: only fabric-managed prefixes, never re-advertise
  external routes back

## Skip if short on time

Exercise 1 (link failure) is the most production-relevant. Exercise
3 (BGP timers) motivates BFD if you plan to teach it later.
