# Session 16 - Verify (UNTESTED predictions)
## 0. Base: chain 01->05a. Hosts: host1 10.100.10.10; host_wan
##    198.51.100.10 gw .1; host_inet 203.0.113.10 gw .1.
## 1. Both eBGP sessions Established:
    ssh admin@clab-vxlan-evpn-leaf1 'show bgp vrf Tenant-A ipv4 unicast summary'
    ssh admin@clab-vxlan-evpn-leaf2 'show bgp vrf Tenant-A ipv4 unicast summary'
## 2. Type-5 re-origination BOTH directions (the transit mechanism):
    ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn route-type 5'
PREDICT: 198.51.100.0/24 (from WEST, re-orig by leaf1) AND 203.0.113.0/24
(from EAST, re-orig by leaf2) both present fabric-wide.
## 3. THE TRANSIT PING - external to external THROUGH the fabric:
    docker exec clab-vxlan-evpn-host_wan ping -c 5 203.0.113.10
PREDICT: works. TTL ~59-60 (extwan + leaf1 + leaf2 + extinet = 4-5 hops).
tcpdump a leaf uplink: the flow rides L3VNI 50001 between borders.
## 4. Fabric host still reaches both (tri-directional):
    docker exec clab-vxlan-evpn-host1 ping -c 3 198.51.100.10
    docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10
## 5. TRANSIT PREVENTION (act 2) - the real-world lesson. On leaf1:
    route-map DENY-TRANSIT deny 10
      match ip address prefix-list EXT-EAST
    route-map DENY-TRANSIT permit 20
    ip prefix-list EXT-EAST permit 203.0.113.0/24
    ...apply OUT toward extwan:  neighbor 192.0.2.5 / af / route-map DENY-TRANSIT out
PREDICT: extwan loses 203.0.113.0/24; transit ping DIES; host1's own
reachability to both survives (fabric prefixes still advertised).
GOTCHA to check: does the leaf advertise EVPN-learned Type-5s to the
eBGP peer at all by default? If step 3 FAILS with no filtering, the
finding is the opposite lesson: re-advertisement needs explicit config.
