# Session 10 — Break It On Purpose

Multi-Pod's instructive failures are about the **IPN underlay** and the
**spine full-mesh** — the two things that join the pods. Break one,
watch inter-pod traffic stop while each pod keeps working internally,
then restore.

`show` on Nexus via `ssh admin@clab-vxlan-evpn-<node>` (password
`admin`); IPN via `docker exec clab-vxlan-evpn-ipn Cli -p15 -c '<cmd>'`.
Start from a known-good lab (see `verify.md`).

---

## 1. Recreate the MTU mismatch ⭐

The signature Multi-Pod gotcha, on demand.

**Break it.** On **spine1**, set the IPN interface back to 9216 (the
NX-OS default that cEOS can't match):

```
configure terminal
interface Ethernet1/3
  mtu 9216
end
```

Bounce the adjacency so it re-negotiates:

```
configure terminal
interface Ethernet1/3
  shutdown
  no shutdown
end
```

**Observe.**

```
docker exec clab-vxlan-evpn-ipn Cli -p15 -c 'show ip ospf neighbor'
```

spine1's adjacency hangs in `EXCH START` (or `EXSTART`) instead of FULL.

```bash
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20   # may still work via spine2
```

**Teaching point.** OSPF requires identical MTU on a point-to-point link
before it will move past database exchange. NX-OS jumbo is 9216; cEOS
caps at 9214. Two bytes, and the adjacency never reaches FULL. Because
spine2 still has the correct 9214, Pod 1 may still reach Pod 2 via spine2
— which is exactly why partial MTU breakage is so sneaky in production:
it degrades redundancy silently rather than failing outright. If you ever
see EXCH START / EXSTART, **MTU is the first suspect**.

**Restore.**

```
configure terminal
interface Ethernet1/3
  mtu 9214
  shutdown
  no shutdown
end
```

Confirm all four IPN neighbors return to FULL.

---

## 2. Drop one spine's cross-pod EVPN sessions

**Break it.** On **spine1**, shut its iBGP-EVPN sessions to Pod 2:

```
configure terminal
router bgp 65000
  neighbor 10.0.0.13
    shutdown
  neighbor 10.0.0.14
    shutdown
end
```

**Observe.**

```
show bgp l2vpn evpn summary       (on spine1)   → spine3/spine4 sessions down
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20   → STILL WORKS
```

**Teaching point.** spine2 still has its full mesh to Pod 2, so cross-pod
routing continues through spine2. This shows why the **full mesh**
matters — it's not just connectivity, it's redundancy. Each pod's routes
reach the other pod as long as *any* spine-to-spine path survives. Lose
the mesh on one spine and you lose a path, not the service.

**Restore.** `no shutdown` both neighbors under `router bgp 65000`.

---

## 3. Take the IPN down entirely

**Break it.** Stop the IPN container:

```bash
docker stop clab-vxlan-evpn-ipn
```

**Observe.**

```
docker exec clab-vxlan-evpn-ipn ... → (container stopped)
# On spine1, OSPF neighbors toward the IPN drop; routes to Pod 2 loopbacks age out.
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20    → 100% loss (cross-pod)
docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10    → STILL WORKS (intra-pod)
```

**Teaching point.** The IPN is the *only* underlay path between pods. Lose
it and all inter-pod traffic stops — but each pod keeps working
internally, because the IPN carries only inter-pod traffic. This is why
production makes the IPN redundant (dual devices, each spine connected to
both): a single IPN failure shouldn't sever the pods.

**Restore.**

```bash
docker start clab-vxlan-evpn-ipn
```

Wait for it to boot and re-establish OSPF (cEOS is quick, ~1–2 min), then
retest the cross-pod ping.

---

## 4. Break the anycast gateway consistency in Pod 2

**Break it.** On **leaf3**, change the VLAN 20 SVI off the anycast IP:

```
configure terminal
interface Vlan20
  no fabric forwarding mode anycast-gateway
end
```

**Observe.**

```bash
docker exec clab-vxlan-evpn-host4 ping -c 3 10.100.20.1     → may fail/degrade
docker exec clab-vxlan-evpn-host4 ping -c 3 10.100.10.10    → cross-subnet routing breaks
```

**Teaching point.** Anycast gateway is what lets host4 use the same
`10.100.20.1` gateway in Pod 2 that Pod 1 hosts use in Pod 1. Remove it
on leaf3 and host4 loses its local first-hop, even though the rest of the
fabric is fine. The anycast gateway is a *per-leaf* property that must be
consistent fabric-wide — including across pods.

**Restore.**

```
configure terminal
interface Vlan20
  fabric forwarding mode anycast-gateway
end
```

---

## What these failures teach, together

| Break | Symptom | Intra-pod | Root cause |
|-------|---------|-----------|------------|
| 1. MTU 9216 on IPN link | OSPF EXCH START | unaffected | MTU must match on P2P OSPF link |
| 2. Shut spine→Pod2 EVPN | cross-pod still works via other spine | unaffected | full mesh = redundancy |
| 3. IPN down | all cross-pod down | **still works** | IPN is sole inter-pod path |
| 4. Remove anycast on leaf3 | host4 first-hop breaks | n/a | anycast GW must be consistent |

The throughline: **breaking the inter-pod glue isolates the pods but
doesn't kill them.** That fault-containment is a feature — each pod is an
independent fabric that degrades gracefully when the join fails. Session
11 (Multi-Site) takes that isolation further, making the pods genuinely
separate autonomous systems.
