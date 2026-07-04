# Session 14 — VXLAN Group Policy Option (GPO) Micro-Segmentation — ⚠ DOC-ONLY / LIKELY UNRUNNABLE

**Status: reference/design spec. Expected NOT to run on this lab.**
GPO needs NX-OS **10.4(3)F+** (ok — we run 10.5(5)) but is gated to
specific Cloud Scale platforms, needs **24 GB+ system memory per
switch**, and enforcement lives in dedicated **Policy TCAM** that the
virtual N9000v very likely does not emulate. Treat this as "how it
works + what you'd configure," with a step-0 gate like Session 13.

## The idea

Everything so far segments at **subnet/VRF granularity** (VLANs, VRFs,
route leaking). GPO segments at **workload granularity inside the same
subnet**: every endpoint is classified into a **Security Group**, the
group tag (SGT) travels **inside the VXLAN header** (the GPO extension —
the reserved bits you saw in Session 3 pcaps become a Group Policy ID),
and the egress leaf enforces **SGACLs (contracts)** between source and
destination groups. It is ACI's EPG/contract model on standalone NX-OS —
the direct bridge to Aung's ACI day job.

## What the config looks like (10.4(3)F+ syntax sketch)

```
feature security-group          ! step-0 gate: accepted on N9000v?

security-group 100 name WEB
security-group 200 name DB

! classification — static, by IP/subnet/VLAN (VM-based needs vCenter):
security-group classification vlan 10 ip 10.100.10.10/32 security-group 100
security-group classification vlan 10 ip 10.100.10.11/32 security-group 200

! the contract:
security-group acl WEB-TO-DB
  permit tcp any any eq 5432
security-group policy source 100 dest 200 acl WEB-TO-DB

! per-VRF enforcement mode:
vrf context Tenant-A
  security-group enforcement mode enforced   ! vs 'monitor' (log-only)
```

Design notes worth teaching even without running it:
- **Monitor vs enforced mode** — production rollout is monitor-first
  (log what *would* drop), exactly like ACI's "unenforced" VRF.
- **Default-deny vs default-permit** per VRF once enforcement is on —
  the blast-radius decision.
- The SGT rides the fabric, so **enforcement is at egress** — the
  ingress leaf tags, the egress leaf applies the SGACL. Contrast with
  a router ACL (single box) and with the L3 route-leak (subnet-level).

## Step 0 — platform gate

```bash
ssh admin@clab-vxlan-evpn-leaf1 'configure terminal ; feature security-group'
```
Expected outcome on vrnetlab N9000v: rejected or accepted-but-inert
(config takes, TCAM programming doesn't). If a same-subnet ping between
two "denied" hosts still passes in enforced mode, the data plane isn't
enforcing — document that finding and keep the session doc-only.

## If it ever runs — the demo

host1 (WEB) and a second host in the SAME VLAN 10 (DB): ping works →
apply default-deny contract → ping dies **with no routing/VLAN change
anywhere** → permit only tcp/5432 → ping still dead, `nc -zv <ip> 5432`
succeeds. Micro-segmentation in four commands.

## Why keep a doc-only session in the repo

The curriculum's arc is subnet → VRF → tenant → pod → site. GPO is the
missing bottom of that ladder (intra-subnet), and interviewers who know
ACI ask about it. An honest "here's the model, our virtual platform
can't enforce it, here's how you'd verify on real hardware" page is
worth more than silence — and flags the lab's limits truthfully.
