# Session 10 — Verify: What Good Looks Like

Work through these in order. Teaching doc:
[`docs/10-multipod.md`](../../docs/10-multipod.md). Bring-up:
[`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md) (Model B / self-contained).

`show` commands run on the Nexus nodes via
`ssh admin@clab-vxlan-evpn-<node>` (password `admin`). The IPN is cEOS —
use `docker exec clab-vxlan-evpn-ipn Cli -p15 -c '<cmd>'`.

---

## 0. All nodes up

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep clab-vxlan
```

Expect 7 N9000v `(healthy)` — spine1, spine2, spine3, spine4, leaf1,
leaf2, leaf3 — plus the IPN (cEOS) and the hosts. `free -h` should show
~55 GB used on a 94 GB VM.

---

## 1. OSPF FULL across the IPN ⭐

The precondition for everything cross-pod.

```bash
docker exec clab-vxlan-evpn-ipn Cli -p15 -c 'show ip ospf neighbor'
```

✅ **Four** neighbors in FULL — spine1, spine2, spine3, spine4.

❌ Any neighbor stuck in `EXCH START` → MTU mismatch. The spines' IPN
interfaces must be MTU **9214** to match the cEOS cap (NX-OS defaults to
9216). Fix the spine `Ethernet1/3` MTU and the adjacency will form. See
break-it #1 and `docs/10-multipod.md` → Lessons #1.

---

## 2. Underlay reaches the far pod's loopbacks

On **spine1**:

```
show ip route 10.0.0.13            (spine3's loopback, Pod 2)
show ip route 10.0.0.23            (leaf3's loopback, Pod 2)
```

✅ Both reachable via the IPN-facing next-hop on Eth1/3. If missing, OSPF
isn't fully converged across the IPN — re-check Test 1.

---

## 3. iBGP-EVPN full mesh between spines

On **spine1**:

```
show bgp l2vpn evpn summary
```

✅ Four neighbors Established:
- `10.0.0.21` (leaf1) and `10.0.0.22` (leaf2) — Pod 1 RR clients
- `10.0.0.13` (spine3) and `10.0.0.14` (spine4) — Pod 2 spines

Each carrying prefixes. The two Pod 2 spine sessions are how Pod 2's
routes reach Pod 1.

---

## 4. Pod 2 host reaches its gateway

```bash
docker exec clab-vxlan-evpn-host4 ip addr show eth1     # expect 10.100.20.20/24
docker exec clab-vxlan-evpn-host4 ping -c 2 10.100.20.1 # anycast GW on leaf3
```

✅ Both succeed. leaf3 answers locally for the anycast gateway — host4
never knows it's in a different pod.

---

## 5. The cross-pod pings (the 4 that matter)

```bash
# [4] First cross-pod ping — same Tenant-A subnet across pods
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20    # TTL 62

# [5] Cross-pod + cross-tenant via Session 5b leak
docker exec clab-vxlan-evpn-host4 ping -c 3 10.200.10.10    # TTL 62

# [6] Pod 2 → Pod 1 L3Out (centralized egress)
docker exec clab-vxlan-evpn-host4 ping -c 3 203.0.113.10    # TTL 61

# [7] External → Pod 2 (through Pod 1 border, across IPN)
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.20.20
```

✅ All succeed. Watch the TTLs: 62 for cross-pod (one extra leaf SVI vs
intra-pod's 63), 61 when the L3Out adds another hop. The TTL decrement
*is* the packet's path made visible.

---

## 6. Confirm the cross-pod route path (optional deep check)

On **leaf3** (Pod 2), confirm it reaches a Pod 1 subnet via a Pod 1 VTEP:

```
show ip route 10.100.10.0/24 vrf Tenant-A
```

✅ Next-hop is a Pod 1 leaf VTEP (e.g. 10.0.1.21), `encap: VXLAN`,
`segid: 50001`. The route was learned via EVPN from Pod 1 and resolves
across the IPN underlay.

---

## Quick all-in-one health snippet

```bash
echo "=== IPN OSPF (want 4x FULL) ==="
docker exec clab-vxlan-evpn-ipn Cli -p15 -c 'show ip ospf neighbor'

echo "=== spine1 EVPN peers (want leaf1/leaf2 + spine3/spine4) ==="
sshpass -p admin ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  admin@clab-vxlan-evpn-spine1 'show bgp l2vpn evpn summary'

echo "=== headline cross-pod ping ==="
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20
```
