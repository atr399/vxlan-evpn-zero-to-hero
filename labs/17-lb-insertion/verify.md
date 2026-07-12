# Session 17 - Verify (UNTESTED predictions)
## 0. Base 01->04. Hosts: host1 10.100.10.10; web1 .20.21; web2 .20.22;
##    lb 10.100.20.50 (+VIP 10.100.99.99/32 on lo). All gw 10.100.20.1.
## 1. Backends: python3 -m http.server 80 (or busybox httpd) on web1/web2
##    serving a page that names the host ("web1"/"web2").
##    Install BEFORE fabric routes (the apk route-flip trap).
## 2. lb: apk add haproxy. Config: frontend bind 10.100.99.99:80,
##    balance roundrobin, TWO backends, and the ONE-ARM KEY:
##      source 10.100.20.50    (SNAT - forces returns back via lb)
##    Plus: ip addr add 10.100.99.99/32 dev lo  (own the VIP)
## 3. THE TEST:
    docker exec clab-vxlan-evpn-host1 sh -c 'for i in 1 2 3 4; do wget -qO- http://10.100.99.99; done'
PREDICT: web1 web2 web1 web2 - round robin through the VIP.
## 4. THE LESSON - remove the 'source' SNAT line, restart haproxy:
PREDICT: requests hang/reset. Why: web1 sees the CLIENT ip (10.100.10.10)
as source, replies DIRECTLY via its gateway - bypassing the lb - and
the client gets packets from 10.100.20.21 for a session it opened to
10.100.99.99 -> RST. The return-path triangle, live.
   tcpdump on web1 (src addresses) makes it visible.
## 5. Kill web1 (docker stop): haproxy health-check marks it down,
    all requests -> web2. Restore, rebalance.
