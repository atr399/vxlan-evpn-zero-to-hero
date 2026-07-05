# Session 12 - Break It (the first three happened for real during the build)

## 1. The anycast giaddr trap (remove source-interface)
    no ip dhcp relay source-interface loopback99   (under Vlan10)
Predict + verified: DISCOVER relays (Tx increments), server OFFERs, but
Offer Rx stays 0 - the OFFER targets giaddr 10.100.10.1, and the LEAF
NEXT TO THE SERVER owns that anycast address too, so it consumes the
packet. Client: 100% discover timeout. THE core lesson of this lab.
Fix: restore source-interface.

## 2. The wrong-server deadlock (swap Kea for dnsmasq)
dnsmasq 2.91 offers correctly but silently ignores every DHCPREQUEST:
the NX-OS server-ID override (option 54 = 10.100.10.1) fails dnsmasq's
"is this REQUEST for me?" check. dhcp-proxy and dhcp-proxy=<relay-ip>
do NOT fix it (both verified). Signature: client loops on
"broadcasting select", dnsmasq logs bare "available DHCP range" pairs
with no DHCPREQUEST line. Lesson: the relay design constrains the
server choice - use a full RFC 5107/3527 implementation (Kea, Infoblox).

## 3. The hidden coupling (remove information option)
    no ip dhcp relay information option
Verified: relay silently drops EVERY packet - Discover Rx climbs, Tx
frozen, and the only clue is the "Option 82 validation failed" drop
counter. On NX-OS 10.5(5), source-interface relay REQUIRES the
information-option lines. Restore both.

## 4. Duplicate giaddr (set leaf2's loopback99 to 10.99.99.1 too)
Predict (untested): returns flap between leaves / intermittent OFFER
loss depending on which leaf's Type-5 wins - the same class of bug as
break-it #1. The giaddr must be unique PER LEAF.
