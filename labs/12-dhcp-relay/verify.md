# Session 12 - Verify (all outputs field-verified 2026-07-05)

## 0. Server host (host2, VLAN 20) - Kea, NOT dnsmasq (see doc: dnsmasq
##    2.91 cannot handle NX-OS's RFC-5107 server-ID override, even in
##    dhcp-proxy mode - verified failure)
    # Install packages BEFORE fabric host-setup, or flip default to eth0:
    docker exec clab-vxlan-evpn-host2 sh -c 'ip route replace default via 172.20.20.1 dev eth0; apk add --no-cache kea-dhcp4; ip route replace default via 10.100.20.1 dev eth1'
    docker exec clab-vxlan-evpn-host2 mkdir -p /run/kea    # Kea fatal-errors without it
Kea config: subnet 10.100.10.0/24, pool .100-.150, routers 10.100.10.1,
and the key line ->  "relay": { "ip-addresses": [ "10.99.99.1" ] }
(explicit giaddr->subnet mapping; no reliance on option-82 interpretation)
Run foreground:  docker exec -it clab-vxlan-evpn-host2 kea-dhcp4 -c /etc/kea/kea-dhcp4.conf
Expect: DHCP4_STARTED, listening on eth1.

## 1. The ask
    docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; ip link set eth1 up; timeout 25 udhcpc -i eth1 -n -q'
SUCCESS = the word "obtained":  lease of 10.100.10.100 obtained from 10.100.10.1
(exit code alone can lie - a Ctrl-C also gives 0.)

## 2. Kea narrates the DORA
DHCPDISCOVER received from 10.99.99.1 -> DHCP4_LEASE_OFFER ->
DHCPREQUEST -> DHCP4_LEASE_ALLOC -> DHCPACK to 10.99.99.1.
The "from 10.99.99.1" is the unique giaddr doing its job.

## 3. Relay counters on leaf1
    ssh admin@clab-vxlan-evpn-leaf1 'show ip dhcp relay statistics'
Want: Discover/Offer/Request/Ack all Rx=Tx and Ack >= 1.
Drops with "Option 82 validation failed" = the information-option lines
are missing (the NX-OS coupling - see break-it #3).

## 4. The leased host actually works
    docker exec clab-vxlan-evpn-host1 ip route          # default via 10.100.10.1 FROM THE LEASE
    docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1     # TTL 255
    docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.10    # TTL 62 - symmetric IRB on a DHCP'd address

## Client note
Client sees "server 10.100.10.1" (the NX-OS server-ID override) even
though the real server is 10.100.20.10 - that is RFC 5107 working as
designed: renewals go via the relay/SVI, not directly to the server.
