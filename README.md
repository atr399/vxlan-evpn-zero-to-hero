# VXLAN-EVPN: Zero to Hero

A hands-on, session-by-session learning path to VXLAN-EVPN on Cisco Nexus, built
to take you from "I've heard the terms" to "I can design and troubleshoot a
real fabric with multi-pod and multi-site."

Every session is a self-contained lab. Clone this repo, follow the
prerequisites once, then for each session: `./scripts/deploy.sh <session>` and
you land at a known-good starting point with configs already applied.

## Why this exists

Most VXLAN-EVPN tutorials online have one of two problems:

1. They drop a finished config on you and walk through what each line does. You
   can copy it but you can't reproduce it from scratch.
2. They lab a single piece in isolation. You learn the L2VNI command set but
   never see how it ties together with vPC, L3Out, or multi-site.

This repo does it differently:

- **Build order matches reality.** Underlay first, then overlay control plane,
  then services on top. Same order a real deployment is built in.
- **Why before how.** Each session explains the problem we're solving and the
  alternatives we rejected before showing the config.
- **Break it on purpose.** Every session ends with a "break-it" exercise:
  shut a link, remove a route, see what happens. You don't understand a
  protocol until you've watched it fail.
- **Reproducible.** All labs run on the same 4-node fabric (2 spines, 2 leaves)
  plus 2 hosts. The topology is identical across sessions; only the configs
  change.

## Session map

| #   | Topic                         | What you'll build                                   |
|-----|-------------------------------|-----------------------------------------------------|
| 00  | Prerequisites                 | Build the lab platform (GCP or local)               |
| 01  | Underlay (OSPF)               | IP reachability between every device's loopback     |
| 02  | Overlay (BGP EVPN)            | iBGP EVPN sessions, spines as route reflectors      |
| 03  | L2VNI                         | Stretch one VLAN across leaves, host-to-host ping   |
| 04  | Anycast gateway + Symmetric IRB | First-hop gateway on every leaf                   |
| 05  | L3VNI                         | Inter-VRF routing across the fabric                 |
| 06  | vPC                           | Dual-attach hosts to a pair of leaves               |
| 07  | Refactor: eBGP underlay       | Why production fabrics drop OSPF                    |
| 08  | L2Out                         | Extend a VLAN to a legacy switch outside the fabric |
| 09  | L3Out                         | BGP peering with an external router                 |
| 10  | Multi-Pod                     | Two pods connected via IPN                          |
| 11  | Multi-Site                    | Separate fabrics joined via BGW + DCI               |
| App | Flood-and-learn (reference)   | Why we don't use this anymore, but should know it   |

## Topology

Every session uses the same physical topology:

```
                  spine1            spine2
                  /    \            /    \
                 /      \          /      \
                /        \        /        \
              leaf1       leaf2
               |            |
             host1        host2
```

- **Spines**: spine1, spine2 (Cisco Nexus 9000v)
- **Leaves**: leaf1, leaf2 (Cisco Nexus 9000v)
- **Hosts**: host1, host2 (Alpine Linux)
- Each leaf has two uplinks (one to each spine)
- Each host attaches to one leaf

## Quick start

1. Follow **[docs/00-prerequisites.md](docs/00-prerequisites.md)** once to
   build the lab platform. This walks through GCP setup, Docker, containerlab,
   and the Cisco image build.
2. Pick a session and deploy:
   ```bash
   ./scripts/deploy.sh 01-underlay
   ```
3. Open the matching doc, e.g. `docs/01-underlay-ospf.md`, and read alongside
   the live lab.
4. When done: `./scripts/reset.sh 01-underlay` tears the lab down and brings
   it back up clean.

## Status

This repo is built in public, session by session. Sessions are added as they
are tested end-to-end on a real lab. PRs and issues welcome — especially if
you spot a config error or a teaching gap.

## License

MIT. Use, modify, teach with it. Attribution appreciated but not required.
