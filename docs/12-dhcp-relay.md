# Session 12: DHCP Relay in the Overlay — Distributed Anycast Gateway

> **STATUS: VERIFIED.** Built live on the 01→04 chain. Three real failures
> were hit and captured before the working design (all now in break-it.md):
> (1) anycast-giaddr trap — OFFERs eaten by the server-side leaf,
> (2) dnsmasq 2.91 cannot handle NX-OS's RFC-5107 server-ID override
> (dhcp-proxy included), (3) NX-OS `source-interface` relay silently
> drops everything without `information option` ("Option 82 validation
> failed" counter). Final working stack: **unique loopback99 giaddr per
> leaf + information option + option vpn + Kea 3.0.3 with an explicit
> `"relay"` giaddr→subnet mapping.** Full DORA verified: lease
> 10.100.10.100/7200s, gateway TTL 255, cross-subnet TTL 62.

## Environment gotchas (verified)
- Install packages **before** fabric host-setup, or flip the default
  route to eth0 for `apk` (fabric default = no internet).
- Kea needs `mkdir -p /run/kea` in the Alpine container or it fatals.
- ISC dhcpd is EOL and gone from Alpine — Kea is the successor.
- dnsmasq is unsuitable behind this relay design (break-it #2).


**Prerequisites**: Sessions 1–9 understood (anycast gateway, VRFs, L3Out).
This session is **self-contained** (Model B) and builds on the Session 9
topology — it reuses the L3Out path to reach a central DHCP server.

**Goal**: Make real hosts get their addresses by DHCP instead of static
assignment. With distributed anycast gateways, a host's DHCP broadcast
is answered by its *local* leaf acting as a relay agent — which has to
solve a problem that doesn't exist in classic networks: every leaf owns
the *same* gateway IP, so the relay must give the DHCP server a way to
reply to the *specific* leaf and pick the *correct* subnet and tenant.

**Lab folder**: `labs/12-dhcp-relay/`

**Estimated time**: 35–45 minutes.

**Why this matters**: Almost nothing in a real data center uses static
IPs. Servers, VMs, PXE-booting bare metal, containers — they DHCP. Every
production VXLAN-EVPN fabric runs DHCP relay, and it's one of the first
services stood up after the fabric itself. It also exposes a subtle
truth about anycast gateways that the earlier sessions glossed over:
"the same IP on every leaf" is wonderful for forwarding and a genuine
problem for any protocol that needs to reply to *one specific* leaf.

---

## Mental model

In a classic network, DHCP relay is boring: the client broadcasts, the
router stamps its own interface IP into the `giaddr` field, unicasts the
request to the server, and the server uses `giaddr` both to pick the
subnet (scope) and to address its reply. One router, one gateway IP, no
ambiguity.

In a **distributed anycast gateway** fabric, that breaks in two ways:

1. **Which subnet?** Every leaf's client SVI uses the *same* anycast IP
   (e.g. `10.100.10.1`). If the relay stamps that as `giaddr`, the
   server can't tell VLAN 10 from any other VLAN sharing the anycast
   scheme, and worse — the reply addressed to `10.100.10.1` could land
   on *any* leaf, because they all own it.

2. **Which tenant?** The same subnet can exist in two VRFs (overlapping
   tenant addressing is the whole point of VRFs). The server needs to
   know *which* tenant a request came from to pick the right pool.

The fix is three coordinated pieces:

- **A unique per-leaf, per-VRF loopback as the relay source / `giaddr`.**
  Not the anycast IP — a real, unique address per leaf. The server's
  reply is addressed *here*, so it returns to the exact leaf that
  relayed it. This loopback is advertised into the tenant VRF's BGP so
  it's reachable fabric-wide.

- **Option 82 sub-options.** The relay attaches metadata: the
  **Link Selection** sub-option tells the server the *client's* real
  subnet (separate from `giaddr`), and the **VPN/VRF** sub-option tells
  the server which tenant the request belongs to. The server uses these
  to pick the correct scope and pool while still replying to the
  loopback `giaddr`.

- **`ip dhcp relay source-interface`** pointing at that loopback, so the
  relayed packet is sourced from the unique address rather than the
  anycast SVI.

```
   host5 (no IP yet)                          DHCP server
   DHCPDISCOVER broadcast                     10.99.99.10 (behind L3Out)
        |                                            ^
        v                                            |
   leaf  (relay agent)                               |
   - giaddr  = its own per-VRF loopback (unique)  ---+  reply comes back
   - Opt82 link-selection = client subnet            |  to the loopback,
   - Opt82 vpn = tenant VRF                           |  not the anycast IP
   - source-interface = that loopback                 |
        |                                             |
        +----- unicast across fabric / L3Out ---------+
```

The elegant part: forwarding still uses the anycast gateway (great for
data plane), while DHCP uses the unique loopback (correct for the
control exchange). Two addresses, two jobs.

---

## Architecture decisions for this session

**Decision 1: One central DHCP server reached across the fabric**

We place a single DHCP server on the external segment behind the L3Out
(reusing Session 9's extrouter path). This is the most common real
pattern — centralized DHCP/IPAM, reached by every leaf relay across the
fabric. Alternatives (a server in a dedicated shared-services VRF, or
per-pod servers) use the same relay mechanics; only the reachability
path differs.

**Decision 2: Unique per-VRF loopback per leaf as `giaddr`**

This is *the* anycast-gateway DHCP requirement. Each leaf gets a unique
loopback in Tenant-A (e.g. leaf1 `10.99.0.21/32`, leaf2 `10.99.0.22/32`),
advertised into the tenant VRF. The relay sources from it and uses it as
`giaddr`, so replies route back to the exact relaying leaf — never
black-holed by the shared anycast IP.

**Decision 3: The relay loopback must NOT be inside any DHCP scope**

The `giaddr`/source loopback is leaf infrastructure, not a client
address. If it falls inside a pool the server hands out, you get address
conflicts and intermittent, maddening failures. We deliberately put the
relay loopbacks in `10.99.0.0/24` — completely separate from the client
scope `10.100.10.0/24`. (This is break-it #2 — a real, common mistake.)

**Decision 4: Option 82 with the VPN sub-option on**

We enable `ip dhcp relay information option` (Option 82) and
`ip dhcp relay information option vpn` (the VRF sub-option). Even though
our lab has one tenant, turning it on is correct production hygiene and
lets the server distinguish tenants the moment a second VRF appears. The
server (dnsmasq) is configured to accept relayed requests and key its
scope on the link-selection sub-option.

**Decision 5: dnsmasq as the DHCP server**

Lightweight, scriptable, runs in the existing Alpine container. From the
relay's perspective it's indistinguishable from an enterprise IPAM
appliance (Infoblox, Windows DHCP, ISC Kea) — they all speak the same
relayed-DHCP + Option 82 protocol.

---

## Topology and addressing

Built on the Session 9 L3Out topology. The DHCP server lives on the
external LAN behind extrouter (or, equivalently, on a dedicated server
host on that segment).

```
   host1 (DHCP client)        host2 (DHCP client)
   VLAN 10, Tenant-A          VLAN 20, Tenant-A
   wants 10.100.10.0/24       wants 10.100.20.0/24
      |                          |
    leaf1                      leaf2
    relay lo: 10.99.0.21       relay lo: 10.99.0.22   (per-VRF, unique)
    anycast gw 10.100.10.1     anycast gw 10.100.20.1
      \                          /
       === fabric (Tenant-A L3VNI 50001) ===
                    |
                 L3Out (Session 9 eBGP)
                    |
                extrouter ---- dhcp-server (dnsmasq)
                               10.99.99.10
                               scope: 10.100.10.100-200
                                      10.100.20.100-200
```

| Element | Value |
|---------|-------|
| DHCP server | `10.99.99.10` (external, reached via L3Out) |
| leaf1 relay loopback (Tenant-A) | `10.99.0.21/32` |
| leaf2 relay loopback (Tenant-A) | `10.99.0.22/32` |
| VLAN 10 client scope | `10.100.10.100 – 10.100.10.200` |
| VLAN 20 client scope | `10.100.20.100 – 10.100.20.200` |
| relay loopback subnet | `10.99.0.0/24` — **outside every scope** |

---

## What's special in the config

**Global (each leaf):**

```
feature dhcp
service dhcp
ip dhcp relay
ip dhcp relay information option          ! Option 82
ip dhcp relay information option vpn       ! VRF sub-option
```

**Per-VRF relay loopback (unique per leaf):**

```
interface loopback99
  vrf member Tenant-A
  ip address 10.99.0.21/32                 ! .22 on leaf2 — UNIQUE per leaf
```

Advertise it into the tenant VRF so the server's reply can route back:

```
router bgp 65000
  vrf Tenant-A
    address-family ipv4 unicast
      redistribute direct route-map ALL_ROUTES   ! already present from S4;
                                                  ! picks up loopback99 too
```

**On each client SVI:**

```
interface Vlan10
  vrf member Tenant-A
  ip address 10.100.10.1/24
  fabric forwarding mode anycast-gateway
  ip dhcp relay address 10.99.99.10                ! the DHCP server
  ip dhcp relay source-interface loopback99         ! the UNIQUE giaddr
```

The two relay lines on the SVI are the heart of it: *where to send the
request* (`relay address`) and *what to stamp as `giaddr` / source from*
(`source-interface`).

---

## Bring-up

Self-contained (Model B), built on the Session 9 topology.

```bash
cd ~/vxlan-evpn-zero-to-hero

containerlab destroy -t labs/<current>/topology.clab.yml --cleanup
./scripts/deploy.sh 12-dhcp-relay
watch -n 10 'docker ps --format "{{.Names}}\t{{.Status}}" | grep clab-vxlan'

./scripts/switch.sh 12-dhcp-relay      # pushes relay config to leaves

# Start the DHCP server (dnsmasq on the server host):
docker exec clab-vxlan-evpn-dhcp-server sh -c '
  apk add --no-cache dnsmasq >/dev/null 2>&1
  cat > /etc/dnsmasq.conf << EOF
port=0
dhcp-relay=10.99.99.10
# scope keyed on the relayed subnet (link-selection sub-option):
dhcp-range=set:v10,10.100.10.100,10.100.10.200,255.255.255.0,12h
dhcp-range=set:v20,10.100.20.100,10.100.20.200,255.255.255.0,12h
dhcp-option=tag:v10,3,10.100.10.1
dhcp-option=tag:v20,3,10.100.20.1
log-dhcp
EOF
  ip addr add 10.99.99.10/24 dev eth1 2>/dev/null
  ip link set eth1 up
  pkill dnsmasq 2>/dev/null
  dnsmasq -C /etc/dnsmasq.conf -d &
'

# Make the clients request DHCP instead of static:
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
```

> The exact dnsmasq invocation and the server-host wiring are provided
> in full in the lab's `switch.sh` output and `verify.md`. A real IPAM
> appliance would replace dnsmasq with zero change to the leaf relay
> config.

---

## Key tests after deployment

### Test 1: Client gets a lease in the right scope

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
docker exec clab-vxlan-evpn-host1 ip addr show eth1
```

Expected: an address in `10.100.10.100–200` (VLAN 10's scope), default
route via `10.100.10.1`. host2 (VLAN 20) gets one in `10.100.20.100–200`.

### Test 2: The relay sourced from the unique loopback

On **leaf1**:

```
show ip dhcp relay address
show ip dhcp relay information option
```

Expected: relay address `10.99.99.10`, Option 82 enabled with the vpn
sub-option, source-interface `loopback99`.

### Test 3: The server saw the right giaddr and link-selection

On the server:

```bash
docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread 2>/dev/null | grep -i dhcp | tail -20'
```

Expected: DHCPDISCOVER/OFFER/REQUEST/ACK, with `giaddr` = the leaf's
`10.99.0.21` loopback (NOT the anycast `10.100.10.1`), and the
link-selection sub-option carrying the client subnet.

### Test 4: Reply routes back to the relaying leaf

On **leaf1**:

```
show ip route 10.99.99.0/24 vrf Tenant-A
show bgp l2vpn evpn | include 10.99.0.21
```

Expected: the server subnet reachable in Tenant-A (via L3Out), and
leaf1's relay loopback `10.99.0.21` advertised into EVPN so the server's
unicast reply finds its way back across the fabric.

---

## Lessons from the build

**1. Anycast gateway is a forwarding feature that fights control
protocols.** Everything that makes anycast great for the data plane —
same IP everywhere, any leaf answers — is exactly what breaks DHCP,
which needs to reply to *one specific* relay. The unique per-VRF
loopback is the reconciliation. Once you've seen this, you'll recognize
the same shape in other "reply to the specific box" problems on anycast
fabrics.

**2. The relay loopback must live outside every DHCP scope.** Put it
inside a pool and the server may hand that exact address to a client,
and now two things own it — the leaf and a host. The failure is
intermittent and points everywhere except the real cause. Keep relay
infrastructure addressing in its own block (`10.99.0.0/24` here),
provably disjoint from client scopes. (Break-it #2.)

**3. `giaddr` selects reachability; link-selection selects scope.** The
classic single-router assumption — "`giaddr` is both how you reach me
*and* which subnet to assign" — is false on an anycast fabric. They're
split: `giaddr` is the unique loopback (reachability), link-selection is
the client subnet (scope). A DHCP server that doesn't understand Option
82 link-selection will assign from the *loopback's* subnet and fail.
Your IPAM must speak Option 82. (Break-it #3.)

**4. Don't forget to advertise the relay loopback into the tenant VRF.**
If `loopback99` isn't redistributed into Tenant-A's BGP, the request
goes out fine but the server's reply has nowhere to route — silent
one-way failure. The `redistribute direct` from Session 4 already covers
it, but only if the loopback is a `vrf member Tenant-A`. (Break-it #1.)

---

## Production patterns we're foreshadowing

**Redundant DHCP servers.** Production lists two (or more)
`ip dhcp relay address` lines per SVI — the relay forwards to all of
them; the client takes the first OFFER. Trivial to add, essential for
availability.

**DHCP snooping + IP Source Guard at the access edge.** Relay gets the
address; snooping makes sure a rogue host can't *be* a DHCP server or
spoof a neighbor's lease. The two are almost always deployed together in
enterprise/bank fabrics.

**IPv6 / DHCPv6 relay.** Same model, different option set
(`ipv6 dhcp relay`), with the LDRA (Lightweight DHCPv6 Relay Agent) at
the access layer. Dual-stack fabrics run both.

**PXE / bare-metal provisioning.** The reason DHCP relay is often
*urgent* in a new fabric: server teams can't image bare metal until
relay works. DHCP Option 66/67 (next-server / boot-file) ride the same
relay path to point machines at a TFTP/HTTP boot source.

**IPAM integration.** Infoblox / Windows DHCP / ISC Kea replace dnsmasq
with no change to the leaf config — the relay protocol is the contract.
The Option 82 VRF sub-option is what lets one IPAM serve hundreds of
overlapping tenants.

---

## What you should be able to explain after Session 12

1. Why distributed anycast gateways make DHCP relay harder than in a
   classic network — the "reply to one specific leaf" problem.
2. Why each leaf needs a *unique* per-VRF loopback as `giaddr`, and why
   it must live outside every DHCP scope.
3. What the Option 82 link-selection and VPN sub-options each do, and
   which one selects the scope vs. the tenant.
4. The split between `giaddr` (reachability) and link-selection (scope)
   — and what breaks if the server ignores Option 82.
5. Why the relay loopback has to be advertised into the tenant VRF.

---

## Next

With DHCP relay, the fabric now provides a real host-facing *service*,
not just connectivity. Natural follow-ons in the operational arc:
**Session 13** layers BFD on the underlay and EVPN sessions plus route
policy on the L3Out (convergence + safety), and **Session 14** hardens
the L2 edge with storm control, the STP boundary, and orphan-port
behaviour.
