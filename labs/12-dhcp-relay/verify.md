# Session 12 — Verify: What Good Looks Like

Teaching doc: [`docs/12-dhcp-relay.md`](../../docs/12-dhcp-relay.md).
Bring-up: [`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md) (Model B).

`show` on the Nexus via `ssh admin@clab-vxlan-evpn-<node>` (password
`admin`). The DHCP server and clients are Alpine containers driven with
`docker exec`.

---

## 0. Lab up + DHCP server running

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep clab-vxlan
docker exec clab-vxlan-evpn-dhcp-server sh -c 'pgrep dnsmasq && echo "dnsmasq up"'
```

✅ All n9kv `(healthy)`, dnsmasq running on the server host with
`10.99.99.10` on its lab interface.

---

## 1. Relay configured on the client SVIs

On **leaf1**:

```
show running-config interface Vlan10
```

✅ Expect under `interface Vlan10`:
- `ip dhcp relay address 10.99.99.10`
- `ip dhcp relay source-interface loopback99`
- `fabric forwarding mode anycast-gateway` (still there — both coexist)

```
show ip dhcp relay
show ip dhcp relay information option
```

✅ Relay enabled, Option 82 on, vpn sub-option on.

---

## 2. The unique relay loopback exists and is in the tenant VRF

On **leaf1**:

```
show running-config interface loopback99
show ip route 10.99.0.21/32 vrf Tenant-A
```

✅ `loopback99` is `vrf member Tenant-A`, IP `10.99.0.21/32` (leaf2:
`.22`). It's a unique address — NOT the anycast `10.100.10.1`.

```
show bgp l2vpn evpn | include 10.99.0.21
```

✅ The loopback is advertised into EVPN (Type-5), so the server's reply
can route back to *this* leaf.

---

## 3. Client gets a lease in the correct scope ⭐

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host1 ip route
```

✅ host1 receives an address in **`10.100.10.100–200`** (VLAN 10 scope),
default route via `10.100.10.1`. Repeat for host2 → expect
`10.100.20.100–200`.

❌ If host1 gets an address in the `10.99.x` range, the server is
keying on `giaddr` instead of the link-selection sub-option — Option 82
handling is wrong (see break-it #3).

---

## 4. The server logged the right giaddr + link selection

```bash
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread 2>/dev/null | grep -i dhcp | tail -25'
```

✅ Look for the DORA exchange (DISCOVER / OFFER / REQUEST / ACK) and:
- `giaddr` = `10.99.0.21` (leaf1's relay loopback) — NOT `10.100.10.1`
- a link-selection sub-option carrying the client subnet
  `10.100.10.0`

This is the proof that `giaddr` (reachability) and scope selection
(link-selection) are correctly *split*.

---

## 5. End-to-end: the leased host actually works

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1          # its anycast gw
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.100        # host2's leased addr (cross-subnet)
```

✅ Both succeed. A DHCP-assigned host behaves exactly like a static one
— the point of the whole exercise.

---

## Quick all-in-one snippet

```bash
echo "=== leaf1 relay config ==="
sshpass -p admin ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  admin@clab-vxlan-evpn-leaf1 \
  'show running-config interface Vlan10 | include "dhcp relay"'

echo "=== lease ==="
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n; ip addr show eth1 | grep inet'

echo "=== server log tail ==="
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread 2>/dev/null | grep -i dhcp | tail -8'
```
