# Session 11 — Verify: What Good Looks Like

Work through these in order. Each step builds on the previous one — if
an early check fails, stop and fix it before moving on, because later
checks depend on it.

Teaching doc: [`docs/11-multisite.md`](../../docs/11-multisite.md).
Bring-up: see [`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md) (this is a
Model B / self-contained session).

All `show` commands are run on the Nexus nodes:
`ssh admin@clab-vxlan-evpn-<node>` (password `admin`).

---

## 0. All nodes up

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep clab-vxlan
```

Expect 5 N9000v `(healthy)` — spine1, spine5, leaf1, leaf2, leaf4 — plus
extrouter (cEOS) and the Alpine hosts. `free -h` should show comfortable
headroom (~45 GB used on a 94 GB VM).

---

## 1. Underlay across the DCI

The single most important precondition. Each BGW must reach the **other
BGW's loopbacks**, or no cross-site tunnel can form.

On **spine1**:

```
show ip ospf neighbors
```

✅ Expect three FULL adjacencies: leaf1, leaf2, **and spine5 across the
DCI** (neighbor `10.0.0.15` on `Eth1/3`).

```
show ip route 10.0.1.15
show ip route 10.0.2.200
```

✅ Both reachable via `192.168.100.1, Eth1/3, ospf-UNDERLAY`. These are
Site 2's PIP and VIP. If either says "Route not found", the DCI OSPF is
one-sided — re-check `ip router ospf UNDERLAY area 0.0.0.0` on **both**
BGWs' Eth1/3.

---

## 2. EVPN sessions — intra-site and cross-site

On **spine1**:

```
show bgp l2vpn evpn summary
```

✅ Three neighbors Established:
- `10.0.0.21` (leaf1) — iBGP, RR client
- `10.0.0.22` (leaf2) — iBGP, RR client
- `192.168.100.1` (spine5) — **eBGP, AS 65001**, with prefixes received

---

## 3. BGW is in Multi-Site mode

On **spine1**:

```
show nve interface nve1 detail
```

✅ Look for:
- `Multisite bgw-if: loopback2 (ip: 10.0.2.100, admin: Up, oper: Up)`
- `Multisite delay-restore time left: 0 seconds`

If `delay-restore time left` is still counting down, wait for it to reach
0 before testing data plane.

---

## 4. Cross-site VTEP learned

On **leaf1**:

```
show nve peers
```

✅ Among the peers, `10.0.1.15` should appear — that's Site 2's BGW VTEP.
Its presence means the stitched cross-site tunnel endpoint is known.
(You'll also see leaf2's VTEP and spine1's PIP locally.)

---

## 5. The cross-site route has the correct next-hop ⭐

This is the check that catches the subtle Multi-Site failure. On
**leaf1**:

```
show ip route 10.100.30.0/24 vrf Tenant-A
```

✅ **Expect** `*via 10.0.2.100` (Site 1's BGW VIP), with
`segid: 50001 ... encap: VXLAN`.

❌ **If you see** `*via 192.168.100.1` (the DCI interface IP), the
next-hop rewrite route-map is not applied or not matching. The control
plane will look fine but **pings will fail**, because the leaf is trying
to build a VXLAN tunnel to a routed-link IP that is not a VTEP. Fix the
`SET-NH-VIP` route-map on spine1 before continuing (see break-it #4 and
`docs/11-multisite.md` → Lessons #3).

On **leaf4**, the mirror check:

```
show ip route 10.100.10.0/24 vrf Tenant-A
```

✅ Expect `*via 10.0.2.200` (Site 2's BGW VIP).

---

## 6. End-to-end connectivity (the 7 tests)

These are exactly what `deploy-final.sh` runs. You can re-run them by
hand any time:

```bash
# Regression — Site 1 internal (must still work)
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10   # [1] cross-tenant via leak
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10   # [2] L2Out
docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10   # [3] L3Out

# Cross-site — the point of this session
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10           # [4] Site1 → Site2
docker exec clab-vxlan-evpn-host5 ping -c 3 10.100.10.10           # [5] Site2 → Site1
docker exec clab-vxlan-evpn-host5 ping -c 3 203.0.113.10           # [6] Site2 → L3Out via Site1
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.30.10   # [7] external → Site2
```

✅ All seven succeed (0% loss after convergence). Tests 6 and 7 are the
showcase: a Site 2 host reaching the internet through Site 1's border,
and an external host reaching Site 2 — traffic crossing the DCI in both
directions and being stitched at each BGW.

> First-run note: if [4]–[7] fail immediately after deploy, wait ~60 s
> for the DCI session and delay-restore, then retry before debugging.
> ARP/ND also needs a moment on first contact, so a single dropped first
> packet is normal.

---

## Quick all-in-one health snippet

```bash
for n in spine1 spine5; do
  echo "=== $n ==="
  sshpass -p admin ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    admin@clab-vxlan-evpn-$n \
    'show nve interface nve1 detail | include "bgw-if|delay-restore time left"'
done

echo "=== leaf1 cross-site route (want next-hop 10.0.2.100) ==="
sshpass -p admin ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  admin@clab-vxlan-evpn-leaf1 'show ip route 10.100.30.0/24 vrf Tenant-A'
```
