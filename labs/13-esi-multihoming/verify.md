# Session 13 - Verify (UNTESTED - expected outcomes from design)

## 0. Platform gate (run FIRST - decides if this session exists)
    ssh admin@clab-vxlan-evpn-leaf1 'configure terminal ; feature evpn esi multihoming'
REJECTED/hidden -> stop: session is doc-only on vrnetlab. Record the finding.

## 1. Both leaves advertise the segment (Type-4)
    ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn route-type 4'
Expect: ES route for ESI 2001 from BOTH VTEPs.

## 2. DF election
    ssh admin@clab-vxlan-evpn-leaf1 'show nve ethernet-segment'
Expect: ESI 2001, two peers listed, exactly ONE Designated Forwarder.

## 3. Type-1 A-D routes present
    ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn route-type 1'

## 4. host1 bond up (same sysfs bond as Session 6b - unchanged host side)
    docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | head -3
Wait 30s after bond setup (the standard LACP wait).

## 5. Data path + aliasing
    docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.10.1
On a remote leaf: host1's MAC should list BOTH VTEP next-hops (aliasing) -
NOT a single shared VIP (there is no VIP here; that was vPC).

## 6. BUM sanity (the part most likely broken on a virtual data plane)
    docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.255 -b
Expect: no duplicate replies (DF filtering). Duplicates -> N9000v is not
enforcing DF in the data plane; document as platform limitation.
