# Session 17 - Break It (UNTESTED)
1. VIP without the /32 static on leaf2 - who answers ARP for 10.100.99.99?
   Nobody (it's not in 10.100.20.0/24 and not on any SVI). The static-to-
   next-hop is what makes an off-subnet VIP routable. Remove it, watch.
2. Put the VIP INSIDE the subnet (10.100.20.99 on lo, no static) -
   now it works via ARP alone? Only if lb answers ARP for it (arp_ignore
   settings) - the L2-VIP vs L3-VIP design fork.
3. DSR thought experiment (direct server return): why does it need the
   VIP on every backend's loopback + ARP suppression - and why does our
   fabric's ARP suppression make DSR extra weird? Discuss vs test.
