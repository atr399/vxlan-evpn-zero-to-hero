# IP Addressing Plan

This is the canonical IP plan used across every session. If a config in
any lab disagrees with this document, this document wins — fix the config.

The plan is deliberately simple so you can read an interface IP and know
exactly which device and link it belongs to.

## Device IDs

Each device has a numeric ID used as the last octet of its loopback and
as the spine/leaf marker:

| Device  | ID   | Role  |
|---------|------|-------|
| spine1  | 11   | spine |
| spine2  | 12   | spine |
| leaf1   | 21   | leaf  |
| leaf2   | 22   | leaf  |

Convention: spines are in the `1X` range, leaves in the `2X` range. When
we add more leaves later (session 6+) they continue as 23, 24, etc.

## Loopback0 — Router-ID

Used as OSPF router-id, BGP router-id, and management/identification.
Always reachable via the underlay. Never moves.

| Device  | Loopback0     |
|---------|---------------|
| spine1  | 10.0.0.11/32  |
| spine2  | 10.0.0.12/32  |
| leaf1   | 10.0.0.21/32  |
| leaf2   | 10.0.0.22/32  |

## Loopback1 — VTEP source (leaves only)

The NVE source interface. This is the IP that appears as the VXLAN tunnel
endpoint in BGP-EVPN advertisements. Spines don't have this — they only
forward IP packets in the underlay; they don't terminate VXLAN tunnels.

| Device  | Loopback1     |
|---------|---------------|
| leaf1   | 10.0.1.21/32  |
| leaf2   | 10.0.1.22/32  |

## P2P underlay links (/31s)

Numbering scheme: `10.10.<link-id>.0/31`. The spine side is always `.0`,
the leaf side always `.1`. Reading any P2P IP, you immediately know
which side you're on.

| Link ID | Subnet         | From          | To            |
|---------|----------------|---------------|---------------|
| 1       | 10.10.1.0/31   | spine1 Eth1/1 | leaf1  Eth1/1 |
| 2       | 10.10.2.0/31   | spine1 Eth1/2 | leaf2  Eth1/1 |
| 3       | 10.10.3.0/31   | spine2 Eth1/1 | leaf1  Eth1/2 |
| 4       | 10.10.4.0/31   | spine2 Eth1/2 | leaf2  Eth1/2 |

## Host-facing interfaces (leaves only)

These are L2 access ports starting in session 3. Eth1/3 reserved on
every leaf for the local host.

| Device  | Port    | Connects to    |
|---------|---------|----------------|
| leaf1   | Eth1/3  | host1          |
| leaf2   | Eth1/3  | host2          |

## Tenant address spaces (introduced in session 3+)

These do NOT appear in the underlay — they're inside VRFs, carried as
EVPN routes.

| VLAN/VNI | Subnet         | Purpose                  | Session  |
|----------|----------------|--------------------------|----------|
| VLAN 10  | 10.100.10.0/24 | Tenant A, web tier       | 03       |
| VLAN 20  | 10.100.20.0/24 | Tenant A, app tier       | 04+      |
| VLAN 30  | 10.100.30.0/24 | Tenant B (separate VRF)  | 05+      |

Hosts will get specific IPs from these ranges:

| Host    | VLAN 10 (session 3) |
|---------|---------------------|
| host1   | 10.100.10.10/24     |
| host2   | 10.100.10.11/24     |

Default gateway for VLAN 10: `10.100.10.1` (anycast on every leaf from
session 4 onward).

## VNI plan

| Type     | VNI   | Mapped to       |
|----------|-------|-----------------|
| L2VNI    | 10010 | VLAN 10         |
| L2VNI    | 10020 | VLAN 20         |
| L2VNI    | 10030 | VLAN 30         |
| L3VNI    | 50001 | VRF Tenant-A    |
| L3VNI    | 50002 | VRF Tenant-B    |

Convention: L2VNIs are 10000 + VLAN. L3VNIs are 50000 + tenant index.
This makes it instantly obvious in `show` output whether a VNI is L2 or L3.

## AS plan (introduced in session 2)

- **Overlay iBGP**: AS 65000, full mesh from leaves to spines (spines act
  as route reflectors)
- **Underlay eBGP** (session 7+): spines AS 65100, each leaf its own AS
  starting at 65021
