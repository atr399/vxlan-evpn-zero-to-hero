# Reading VXLAN-EVPN Captures in Wireshark

Every session's `pcaps/` folder collects packet captures that prove the
concept being taught. Open them in Wireshark on your PC for a visual
view of the bytes on the wire. This document explains what to look for.

## Workflow

```bash
# 1. In one terminal, start the capture
./scripts/capture.sh leaf1 eth1 my-test 'udp port 4789'

# 2. In another terminal, trigger the traffic
docker exec clab-vxlan-evpn-host1 ping -c 5 10.100.10.11

# 3. Capture stops, file is in labs/<session>/pcaps/

# 4. Download the .pcap to your PC and open in Wireshark
```

## Wireshark display filters worth knowing

Once a pcap is open in Wireshark, type these in the filter bar:

| Filter                | What it shows                                  |
|-----------------------|------------------------------------------------|
| `vxlan`               | All VXLAN-encapsulated frames                  |
| `vxlan.vni == 10010`  | Only traffic in VNI 10010                      |
| `udp.port == 4789`    | All UDP traffic on the VXLAN port              |
| `bgp`                 | All BGP messages (Open, Update, Keepalive)    |
| `bgp.evpn`            | BGP EVPN address-family routes                 |
| `ospf`                | OSPF hellos, LSAs                              |
| `arp`                 | ARP requests/replies (often inside VXLAN)      |
| `icmp`                | ICMP (ping) — including the inner frames       |

## Decoding a VXLAN packet

When you click a VXLAN frame in Wireshark, the lower pane shows the
protocol layers. You'll see this stack from top to bottom:

```
Ethernet II         <-- outer L2 (between switches in underlay)
Internet Protocol   <-- outer L3 (VTEP source -> VTEP dest)
User Datagram       <-- outer L4 (random src port, dst 4789)
Virtual eXtensible  <-- VXLAN header (carries the VNI)
Ethernet II         <-- inner L2 (the tenant frame)
Internet Protocol   <-- inner L3 (tenant IPs)
... rest of inner ...
```

Two key things to verify visually:

1. **Outer IPs are VTEP loopbacks** (10.0.1.21, 10.0.1.22). Never
   physical interface IPs.
2. **Inner IPs are tenant addresses** (10.100.10.10, 10.100.10.11).
   These never appear in the underlay routing table.

## What each capture in this repo demonstrates

Captures are named by session number + topic, so you can browse them
chronologically:

- `labs/03-l2vni/pcaps/baseline-vxlan-ping-*.pcap`
  - First VXLAN packets in the curriculum. ICMP inside UDP-4789 inside IP.

- `labs/04-anycast-gw/pcaps/anycast-gw-arp-*.pcap`
  - ARP for the gateway. Watch the same MAC reply from both leaves.

- `labs/04-anycast-gw/pcaps/asymmetric-vs-symmetric-irb-*.pcap`
  - L3 routing happens on the local leaf before VXLAN encap.

(More added per session as we build them.)

## Why captures matter

You can read all the design docs you want, but staring at a real
VXLAN packet teaches things no doc can:

- **Size and overhead**: see the 50-byte VXLAN tax with your own eyes
- **ECMP source-port hashing**: notice how every VXLAN packet has a
  different source UDP port — that's the trick that spreads traffic
  across underlay paths
- **What does NOT change vs. what does**: the inner frame is identical
  to what the host sent; only the outer headers change between leaves
- **Failure shapes**: a broken fabric produces specific packet
  patterns (excessive ARPs, missing replies, MTU-clipped fragments)
  that you learn to spot

Treat the pcaps folder as the **lab notebook** of the curriculum. A
recorded capture is permanent evidence that the lab worked, and it's
the best teaching material for someone coming after you.
