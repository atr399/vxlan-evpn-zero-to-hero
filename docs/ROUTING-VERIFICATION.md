# Routing Verification Deep-Dive — Reading the EVPN Control Plane

A cross-session reference: how to *prove* what the fabric is doing by
reading BGP EVPN output, not just pinging. Run these on the live lab at
the session noted. Content audited against Cisco documentation and this
lab's verified behavior; items marked **⚠ VERIFY** are plausible but not
yet confirmed on this platform — test them before teaching them.

---

## 1. Decoding a raw Type-2 route (Session 3+)

```bash
ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn' | head -40
```

A Type-2 entry reads like:

```
[2]:[0]:[0]:[48]:[aac1.ab5e.c305]:[32]:[10.100.10.10]/272
 │   │   │    │        │            │        │
 │   │   │    │        │            │        └ the host IP
 │   │   │    │        │            └ IP length (32 = IPv4 present)
 │   │   │    │        └ the host MAC
 │   │   │    └ MAC length (always 48)
 │   └───┴ reserved (ESI-related, 0 in single-homed)
 └ route type 2 (MAC/IP)
```

A **MAC-only** Type-2 shows `[0]:[0.0.0.0]` for the IP part — the leaf
learned the MAC but has no ARP entry yet (a *silent host* at L3).

## 2. The extended communities that matter (Session 3+)

```bash
ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn 10.100.10.10' | sed -n '/Advertised path/,$p'
```

| Community | Meaning |
|-----------|---------|
| `RT:65000:10010` | Route Target — which L2VNI/VRF imports this. |
| `ENCAP:8` | Data-plane instruction: use **VXLAN** (tunnel type 8). |
| `Router MAC:0c3b.fe00.1b08` | The advertising leaf's **system router MAC** — what the ingress leaf stamps as inner destination MAC for symmetric IRB (Session 4's packet walk). |
| `SOO:10.0.1.100:0` | Site-of-Origin on vPC-advertised routes — the peer leaf drops routes carrying its own SOO (split-horizon, prevents vPC routing loops). Appears from Session 6c. |

**⚠ VERIFY:** some references claim the gateway/router MAC also appears
as a *standalone* MAC-only Type-2 tagged with the L3VNI. On NX-OS the
router MAC primarily rides as the extended community above. Check
whether a standalone RMAC Type-2 exists at all:
`show bgp l2vpn evpn | include 0.0.0.0` then inspect candidates.

## 3. "Imported to N destinations" = watching route-leak fan-out (Session 5)

```bash
ssh admin@clab-vxlan-evpn-leaf1 'show bgp l2vpn evpn 10.200.10.10' | grep -i import
```

One received route is copied into every table whose RT matches — the
L2VNI bridge table, its home VRF, and (after 5b) the *other* tenant's
VRF. The import count rising when you apply 5b is the leak happening in
the control plane, before any ping.

## 4. Type-5 Gateway IP field (Session 9)

```bash
ssh admin@clab-vxlan-evpn-leaf2 'show bgp l2vpn evpn route-type 5' | head -30
```

`Gateway IP 0.0.0.0` → the prefix is attached at the advertising VTEP
(forward to the route's next-hop VTEP). A non-zero gateway IP means
recursive resolution toward another device (e.g. a firewall behind the
border leaf).

## 5. The dual route-target statements (Session 5) — ⚠ VERIFY the mechanism

Both lines are required for the leak; the *labels* differ across sources:

- `route-target import X` (no keyword) — per Cisco docs, applies to the
  **VPNv4/VPNv6** address families; functionally it is also what admits
  the leaked route into the VRF's IP table on the same box.
- `route-target import X evpn` — applies to the **L2VPN EVPN** table
  (routes arriving over the fabric).

**Break-it test to settle it empirically:** on one leaf, remove only the
non-`evpn` import line for the other tenant. Predicted result: the route
still shows in `show bgp l2vpn evpn` but vanishes from
`show ip route vrf Tenant-A`, and the cross-tenant ping dies. Re-add and
confirm recovery. (Good candidate for `labs/05*/break-it.md`.)

## 6. Multi-Pod control-plane proof (Session 10)

```bash
# Underlay across the IPN — the precondition:
docker exec clab-vxlan-evpn-ipn Cli -p15 -c 'show ip ospf neighbor'   # 4x FULL
# Overlay: spine-to-spine EVPN across pods (NOT leaf-to-leaf):
ssh admin@clab-vxlan-evpn-spine1 'show bgp l2vpn evpn summary'        # spine3 = 10.0.0.13 Established
```

One control plane, one fault domain: a Pod 1 leaf's Type-2 appears
unmodified on a Pod 2 leaf with the *original* VTEP as next-hop.

## 7. Multi-Site stitching proof (Session 11)

```bash
# 1) BGW-to-BGW eBGP-EVPN across the DCI:
ssh admin@clab-vxlan-evpn-spine1 'show bgp l2vpn evpn summary'   # 192.168.100.1 (AS 65001) Established
# 2) The re-origination signature — remote routes carry the BGW VIP:
ssh admin@clab-vxlan-evpn-leaf1 'show ip route 10.100.30.0/24 vrf Tenant-A'
#    want: via 10.0.2.100 (Site2 BGW VIP), NOT 192.168.100.1 (DCI link)
# 3) RT handling across different ASNs — ⚠ VERIFY which mechanism this lab uses:
ssh admin@clab-vxlan-evpn-spine1 'show running-config bgp | include rewrite'
#    expect rewrite-evpn-rt-asn on the DCI peering (auto-RT translation),
#    rather than manual per-VNI RT mapping.
```

Contrast with Multi-Pod: in Multi-Site the next-hop is *rewritten* at
the border (tunnel stitching); in Multi-Pod it is *preserved* end to end.
That single routing-table field is the architectural difference made
visible.

## 8. Spine's role, seen from the table (Session 2+)

```bash
ssh admin@clab-vxlan-evpn-spine1 'show bgp l2vpn evpn summary'
ssh admin@clab-vxlan-evpn-spine1 'show nve peers'    # empty — spines have no VTEPs (until BGW duty in S11)
```

Control plane: route reflector (leaves as clients). Data plane: outer-IP
transit only — no VNI awareness, no NVE peers. (In Session 11 the
collapsed spine+BGW is the deliberate exception.)
