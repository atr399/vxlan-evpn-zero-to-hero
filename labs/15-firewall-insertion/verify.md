# Session 15 - Verify (UNTESTED - predictions to check, Session-12 style)

## 0. Base state: chain 01 -> 05a ONLY (two tenants, isolated - NO 05b!)
Confirm isolation first (this is your Act-0 baseline):
    docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10   # MUST FAIL

## 1. Firewall host setup (fw = router+filter between its two arms)
    docker exec clab-vxlan-evpn-fw sh -c '
    ip addr flush dev eth1; ip addr add 10.100.91.10/24 dev eth1; ip link set eth1 up
    ip addr flush dev eth2; ip addr add 10.200.92.10/24 dev eth2; ip link set eth2 up
    ip route add 10.100.0.0/16 via 10.100.91.1
    ip route add 10.200.0.0/16 via 10.200.92.1
    sysctl -w net.ipv4.ip_forward=1'
(Install nftables BEFORE fabric routes or route-flip: apk add nftables)

## 2. Push leaf configs, then the control-plane check
    ssh admin@clab-vxlan-evpn-leaf1 'show ip route 10.200.10.0/24 vrf Tenant-A'
PREDICT: static via 10.100.91.10 (the fw arm) - NOT a %Tenant-B leak.
On leaf2 the same lookup should recurse over VNI 10091 toward leaf1.

## 3. Act 1a - firewall FORWARDING (no filter yet)
    docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
PREDICT: works, TTL 61 (three routed hops: leaf + fw + leaf vs 63 on the
old leak - the extra decrements ARE the proof traffic transits the fw).
VERIFY the path: tcpdump on fw eth1/eth2 shows the ping in BOTH arms.

## 4. Act 1b - default-deny (the security moment)
    docker exec clab-vxlan-evpn-fw sh -c 'nft add table inet fw
    nft add chain inet fw forward { type filter hook forward priority 0 \; policy drop \; }'
PREDICT: same ping now 100% loss. Routing unchanged - POLICY did that.

## 5. Act 1c - the permit rule
    docker exec clab-vxlan-evpn-fw sh -c 'nft add rule inet fw forward ip saddr 10.100.10.0/24 ip daddr 10.200.10.10 icmp type echo-request accept
    nft add rule inet fw forward ct state established,related accept'
PREDICT: ping works again; a REVERSE-initiated ping (host2->host1) still
FAILS (no rule for it) - stateful directionality demonstrated.

## 6. Act 2 - PBR steering (uncomment the PBR block on leaf1)
Same-tenant host1 -> 10.100.20.x traffic detours via the firewall.
PREDICT: TTL drops by the extra fw hop vs the direct symmetric-IRB path;
tcpdump on fw sees SAME-TENANT traffic. Return path is NOT steered
(asymmetry!) unless you PBR the reverse on Vlan20 - that asymmetry is
the teaching point.

## Predicted gotchas (watch for these - Session-12 experience says
## the failures ARE the lab)
- fw return-route misses (10.100.0.0/16 summary must cover host subnets)
- leaf2's static next-hop 10.100.91.10 must recurse via the EVPN route
  for VLAN91's subnet - if VNI 10091 isn't advertised, leaf2 blackholes
- PBR on anycast SVI: verify NX-OS accepts ip policy on a
  fabric-forwarding SVI - if rejected, that's a FINDING (steer on the
  physical ingress instead)
- ct state rule needs conntrack - if kernel module missing in Alpine,
  use stateless returns (permit echo-reply) and note it
