# VXLAN-EVPN: Zero to Hero

> A hands-on, session-by-session learning path to VXLAN-EVPN on Cisco Nexus.
> From "I've heard the terms" to "I can design and troubleshoot multi-pod
> and multi-site fabrics."

![Status](https://img.shields.io/badge/status-sessions%2000--11%20complete-success)
![Platform](https://img.shields.io/badge/platform-containerlab-orange)
![NOS](https://img.shields.io/badge/NOS-Cisco%20Nexus%209000v-informational)
![License](https://img.shields.io/badge/license-MIT-green)

---

## What this is

> **First time here?** → [QUICKSTART for self-study](docs/QUICKSTART.md)

Every session in this repo is a self-contained lab. Clone the repo,
follow the prerequisites once, then for each session:

```bash
./scripts/deploy.sh <session-folder>
```

You land at a known-good starting point with configs already applied,
ready to verify, experiment with, and break on purpose.

## Who this is for

- **Network engineers** who want to learn VXLAN-EVPN by building it,
  not by reading slides.
- **Engineers preparing for design interviews** at companies running
  modern data center fabrics.
- **Anyone teaching others** — every session has a "why" section, a
  verify checklist, and break-it exercises designed to be reused as
  teaching material.

## Why this repo exists

Most VXLAN-EVPN tutorials online have one of two problems:

1. **They drop a finished config on you and walk through each line.**
   You can copy it but you can't reproduce it from scratch.
2. **They lab one piece in isolation.** You learn the L2VNI command
   set, but never see how it ties together with vPC, L3Out, or
   multi-site.

This repo does it differently:

| Principle               | What it means in practice                                                                                       |
|-------------------------|-----------------------------------------------------------------------------------------------------------------|
| **Build order = reality** | Underlay first, then overlay control plane, then services on top. Same order a real deployment is built in.   |
| **Why before how**       | Each session explains the problem we're solving and the alternatives we rejected before showing the config.   |
| **Break it on purpose**  | Every session ends with break-it exercises: shut a link, remove a route, see what happens.                    |
| **Reproducible**         | Sessions 1–7 run on the same 4-node base fabric (2 spines, 2 leaves) plus hosts — the topology stays, only configs change. Sessions 8–11 add nodes (external gear, extra pods, a second site) in self-contained topologies. |
| **Mental model first**   | Each session opens with an analogy or picture so you hold the concept in your head while learning syntax.     |

## Session map

Sessions 1–7 chain on one running base fabric (push config with
`switch.sh`). Sessions 8–11 are **self-contained** — each boots its own
topology fresh. See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the
exact bring-up of every session.

| #    | Topic                            | What you'll build                                            | Model | Status   |
|:----:|----------------------------------|--------------------------------------------------------------|:-----:|:--------:|
| 00   | Prerequisites                    | Build the lab platform (GCP or local)                        |  —    | ✅ Ready |
| 01   | Underlay (OSPF)                  | IP reachability between every device's loopback              |  A    | ✅ Ready |
| 02   | Overlay (BGP EVPN)               | iBGP EVPN sessions, spines as route reflectors               |  A    | ✅ Ready |
| 03   | L2VNI                            | Stretch one VLAN across leaves, host-to-host ping over VXLAN |  A    | ✅ Ready |
| 04   | Anycast gateway + Symmetric IRB  | First-hop gateway on every leaf                              |  A    | ✅ Ready |
| 05a  | Multi-VRF (Tenant-B)             | Second tenant, VRF isolation                                 |  A    | ✅ Ready |
| 05b  | Route leak                       | Controlled inter-VRF leak via RT import                      |  A    | ✅ Ready |
| 06a  | vPC base                         | Peer-link, peer-keepalive, vPC domain                        |  A    | ✅ Ready |
| 06b  | vPC host bond                    | Dual-attach host with LACP bond                              |  A    | ✅ Ready |
| 06c  | vPC + VXLAN                      | Shared VTEP — the keystone fix                               |  A    | ✅ Ready |
| 07   | Refactor: eBGP underlay          | Why production fabrics drop OSPF (RFC 7938)                  |  A    | ✅ Ready |
| 08   | L2Out                            | Extend a VLAN to a legacy switch outside the fabric          |  B    | ✅ Ready |
| 09   | L3Out                            | BGP peering with an external router                          |  B    | ✅ Ready |
| 10   | Multi-Pod                        | Two pods connected via IPN                                   |  B    | ✅ Ready |
| 11   | Multi-Site                       | Separate fabrics joined via BGW + DCI                        |  B    | ✅ Ready |

*Model A = chain on the base fabric (`deploy` once, then `switch.sh`).
Model B = self-contained (`deploy` the session fresh). Full details in
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).*

## Topology

**Sessions 1–7** use the same physical topology — a full-mesh 2-spine,
2-leaf fabric with one host attached to each leaf. **Sessions 8–11** keep
this fabric as the core and add nodes around it (an external switch, an
external router, extra pods, or a second site); see each session's doc
and [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for those topologies. The
base fabric:

```
            +--------+              +--------+
            | spine1 |              | spine2 |
            +--------+              +--------+
              |    \                /    |
              |     \              /     |
              |      \            /      |
              |       \          /       |
              |        \        /        |
              |         \      /         |
              |          \    /          |
              |           \  /           |
              |            \/            |
              |            /\            |
              |           /  \           |
              |          /    \          |
              |         /      \         |
              |        /        \        |
              |       /          \       |
              |      /            \      |
              |     /              \     |
              |    /                \    |
            +-------+               +-------+
            | leaf1 |               | leaf2 |
            +-------+               +-------+
                |                       |
            +-------+               +-------+
            | host1 |               | host2 |
            +-------+               +-------+
```

**Device roles:**

| Role  | Devices         | Image                      |
|-------|-----------------|----------------------------|
| Spine | spine1, spine2  | Cisco Nexus 9000v (10.5.x) |
| Leaf  | leaf1, leaf2    | Cisco Nexus 9000v (10.5.x) |
| Host  | host1, host2    | Alpine Linux               |

**Link summary:**

- Each leaf has **two uplinks**, one to each spine (full mesh)
- Each host attaches to **one** leaf
- Total: 4 spine-leaf links + 2 host-leaf links = 6 links

For full IP addressing, see [`common/ipplan.md`](common/ipplan.md) —
this is the single source of truth that every session's configs
reference.

## Repo layout

```
vxlan-evpn-zero-to-hero/
├── README.md                          ← you are here
├── common/
│   └── ipplan.md                      ← single IP/AS/VNI plan for the whole curriculum
├── docs/                              ← session-by-session teaching docs
│   ├── DEPLOYMENT.md                  ← how to bring up every session (read this!)
│   ├── 00-prerequisites.md
│   ├── 01-underlay-ospf.md
│   ├── 02-overlay-bgp-evpn.md
│   └── ...                            ← through 11-multisite.md
├── labs/                              ← one folder per session
│   ├── 01-underlay/
│   │   ├── topology.clab.yml          ← containerlab topology file
│   │   ├── configs/                   ← startup config per device
│   │   │   ├── spine1.cfg
│   │   │   ├── spine2.cfg
│   │   │   ├── leaf1.cfg
│   │   │   └── leaf2.cfg
│   │   ├── verify.md                  ← "what good looks like" checklist
│   │   └── break-it.md                ← failure exercises with teaching points
│   └── ...
└── scripts/
    ├── deploy.sh                      ← deploy a session's topology
    ├── switch.sh                      ← push a session's configs onto running nodes
    ├── deploy-final.sh                ← Session 11: push + host setup + smoke tests
    ├── capture.sh                     ← tcpdump helper → .pcap for Wireshark
    └── reset.sh                       ← destroy + redeploy clean
```

## Quick start

> **First-timer?** Start with the [prerequisites guide](docs/00-prerequisites.md).
> It walks through GCP setup (or local VMware) and the Cisco image
> build. Allow ~2 hours the first time.

Once the lab platform is built:

```bash
# 1. Clone the repo
git clone https://github.com/atr399/vxlan-evpn-zero-to-hero.git
cd vxlan-evpn-zero-to-hero

# 2. Deploy a session (15-25 min for Cisco N9000v to boot)
./scripts/deploy.sh 01-underlay

# 3. Open the matching doc and read alongside the live lab
#    e.g. docs/01-underlay-ospf.md

# 4. SSH into devices to verify
ssh admin@clab-vxlan-evpn-spine1     # password: admin

# 5. When done, reset to clean state for the next session
./scripts/reset.sh 01-underlay
```

## What you'll need

| Resource             | Minimum    | Recommended |
|----------------------|------------|-------------|
| Host CPU             | 8 vCPU     | 12+ vCPU    |
| Host RAM             | 32 GB      | 48 GB (96 GB for Sessions 10–11) |
| Host disk            | 60 GB      | 100 GB      |
| Nested virtualization | **Required** — VXLAN labs need this. See [prerequisites](docs/00-prerequisites.md). |
| Cisco N9000v image   | Get from cisco.com (CCO account required) |

Tested on **Ubuntu 24.04 LTS** with **Cisco Nexus 9000v 10.5.x**, both
on GCP (N2 instance) and local VMware Workstation.

## How each session works

Every session folder has the same four files. Once you know one, you
know them all:

| File                   | What it's for                                          |
|------------------------|--------------------------------------------------------|
| `topology.clab.yml`    | Containerlab topology — defines the nodes and links    |
| `configs/<device>.cfg` | The startup config applied to each device on deploy    |
| `verify.md`            | Step-by-step verification — "what good looks like"     |
| `break-it.md`          | Deliberate failure exercises with teaching points      |

And each session has a paired `docs/0X-topic.md` with:

- **Mental model** — the analogy that anchors the concept
- **Why this layer exists** — what problem it solves
- **Design decisions** — why we picked X over Y
- **What you should be able to explain** — self-check questions

### Two bring-up models

How you deploy depends on the session:

- **Sessions 1–7 (Model A)** — all run on the **same base fabric**
  (2 spines, 2 leaves, 2 hosts). Deploy it once with
  `./scripts/deploy.sh 01-underlay`, then advance through sessions by
  pushing config with `./scripts/switch.sh <session>`. No redeploy
  between them; they chain.
- **Sessions 8–11 (Model B)** — each adds new devices (external switch,
  external router, extra pods, a second site), so each has its **own
  self-contained topology**. Tear down the running lab, then
  `./scripts/deploy.sh <session>` to bring the whole thing up fresh.

The full per-session bring-up — which model, which topology, expected
RAM, and the exact command sequence — lives in
**[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)**. Read it before deploying
anything past Session 7.

## Status

✅ **Sessions 00–11 are complete and verified end-to-end** on a real GCP
VM (Ubuntu 24.04, Cisco Nexus 9000v 10.5.x). Every session has been
deployed, brought up, and tested — the "Ready" status in the session map
means exactly that.

The curriculum is built in public, and the hard-won debugging stories
are documented honestly in each session's **Lessons from the build**
section (the MTU mismatch in Session 10, the Multi-Site next-hop rewrite
in Session 11, and more) — because the failures teach as much as the
configs.

Issues and PRs welcome — especially:

- Config errors or typos you spot while running a session
- Teaching gaps where "why" wasn't clear enough
- New break-it exercises that taught you something
- Vendor parity (Arista, SR Linux equivalents for sessions)

## Acknowledgments

- The [containerlab](https://containerlab.dev) team — without their
  tool, this whole project wouldn't be practical.
- The [hellt/vrnetlab](https://github.com/hellt/vrnetlab) fork
  maintainers — they make Cisco qcow2 images playable in containers.
- Every operator who's written a "why VXLAN EVPN works the way it
  does" post over the years. The "why" sections in this repo stand on
  their shoulders.

## License

MIT. Use it, modify it, teach with it. Attribution appreciated but not
required.
