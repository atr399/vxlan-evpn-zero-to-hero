# Session 2: Verification

After `./scripts/deploy.sh 02-overlay` completes and all nodes show
`healthy`, run through these checks.

## Check 1: Underlay still works (regression check)

Always re-verify the underlay before adding overlay checks. If OSPF is
broken, BGP can't come up either.

On spine1:

```
show ip ospf neighbors
```

Two FULL neighbors expected (one per leaf). If this looks broken, fix
the underlay before going further — there's no point debugging BGP if
OSPF is down.

## Check 2: BGP sessions are Established

On spine1:

```
show bgp l2vpn evpn summary
```

Expected:

```
BGP summary information for VRF default, address family L2VPN EVPN
BGP router identifier 10.0.0.11, local AS number 65000
...

Neighbor        V    AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down State/PfxRcd
10.0.0.21       4 65000      X       X        1    0    0 00:0Y:ZZ 0
10.0.0.22       4 65000      X       X        1    0    0 00:0Y:ZZ 0
```

Two neighbors, both with a numeric value (0) in the State/PfxRcd column.
**A number means "Established"** — a state name like `Idle`, `Active`, or
`OpenSent` means the session isn't fully up yet.

On leaf1:

```
show bgp l2vpn evpn summary
```

Same — two neighbors (the two spines), both showing `0` in PfxRcd.

## Check 3: PfxRcd is 0 (correct for this session)

The `0` you see in the State/PfxRcd column is **the right answer for
session 2**. It means: BGP sessions are up and ready to exchange EVPN
prefixes, but neither side has any prefixes to send yet.

In session 3, after we configure the first L2VNI on both leaves, this
number will become non-zero as MAC/IP advertisements flow.

If you see a non-zero number here in session 2, something unexpected is
happening — check that no leftover config from a previous lab is
present.

## Check 4: BGP session is sourced from loopback0

On any device:

```
show bgp l2vpn evpn neighbors 10.0.0.11
```

Look for these lines in the output:

```
BGP neighbor is 10.0.0.11, remote AS 65000, ibgp link, ...
...
Using loopback0 as update source for this peer
...
Local host: 10.0.0.21, Local port: XXXXX
Foreign host: 10.0.0.11, Foreign port: 179
```

The "Using loopback0 as update source" line confirms our design
decision is in effect. Local host should be 10.0.0.21 (the leaf's
loopback0), not a physical interface IP.

## Check 5: Spines see leaves as RR clients

On spine1:

```
show bgp l2vpn evpn neighbors 10.0.0.21 | include "Route-Reflector"
```

Expected:

```
Route-Reflector Client
```

Confirms the spine is treating the leaf as an RR client, which means
spine1 will reflect routes received from leaf1 to leaf2 (and vice
versa). Without this, leaves would never learn each other's routes
through the spine.

## Check 6: Leaves do NOT see spines as RR clients

The relationship is one-directional. The spine reflects routes; the
leaf does not. On leaf1:

```
show bgp l2vpn evpn neighbors 10.0.0.11 | include "Route-Reflector"
```

This should return no output, or explicitly note that this peer is
**not** an RR client. The asymmetry is intentional — only the spines
are configured as RRs in this fabric.

## Check 7: Underlay BGP TCP session lives on real underlay paths

This is a subtle check that confirms the BGP session is taking real
paths through the underlay, not via management.

On leaf1:

```
show ip route 10.0.0.11
```

You should see one or two next-hops via the spine1-leaf1 link
(10.10.1.0), via OSPF. This is the path the BGP TCP session takes.

If you saw the route via mgmt0 or via a default route, BGP would be
riding on the wrong network — but in our setup that doesn't happen
because mgmt0 is in its own VRF.

## Check 8: l2vpn evpn AF is administratively up

On any device:

```
show running-config bgp | section "address-family l2vpn evpn"
```

You should see the address-family blocks for each neighbor, with
`send-community` and `send-community extended` configured. The
extended-community piece is what carries route-targets in EVPN — we'll
make use of it in session 3.

## Summary of what success looks like

- OSPF: 2 FULL neighbors per device (unchanged from session 1)
- BGP: 2 Established sessions per leaf, 2 per spine, all PfxRcd=0
- BGP sessions sourced from loopback0
- Spines see leaves as RR clients; leaves do not see spines as clients
- All sessions are exchanging extended communities

If all 8 checks pass, the overlay control plane is built and ready to
carry actual routes in session 3.
