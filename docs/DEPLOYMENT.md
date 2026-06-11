# How to Bring Up Each Session

> The single reference for deploying any session in this curriculum.
> Read this once; it explains the two deployment models and gives the
> exact command sequence for every session.

---

## The two deployment models

This curriculum has **two** ways a session comes up. Knowing which
model a session uses is the difference between a clean bring-up and a
confusing failure.

### Model A — chain on the base fabric (Sessions 1–7)

Sessions 1 through 7 all run on the **same 4-node topology**
(spine1, spine2, leaf1, leaf2 + hosts). You boot that topology **once**,
then push each session's cumulative config onto the running lab with
`switch.sh`. Sessions build on each other — Session 5 assumes Session 4's
config is already there, and so on.

```
deploy.sh 01-underlay        ← boot the base fabric ONCE (~15 min)
   │
   ├── switch.sh 01-underlay  ← OSPF underlay
   ├── switch.sh 02-overlay   ← add iBGP-EVPN
   ├── switch.sh 03-l2vni     ← add an L2VNI
   ├── ...
   └── switch.sh 07-ebgp-underlay
```

You do **not** re-deploy between these. The containers stay up; only
the configuration changes.

### Model B — self-contained topology (Sessions 8, 9, 10, 11)

Sessions 8 and later add new devices (external switch, external router,
extra pods, a second site). Each of these sessions has its **own
self-contained `topology.clab.yml`** that brings up the full fabric
**plus** that session's extra nodes in one `deploy`. They do not layer
onto a running base lab — you tear down whatever is running, then deploy
the session fresh.

```
containerlab destroy ...     ← tear down the previous lab
   │
deploy.sh 08-l2out           ← boots base fabric + external + host3
   │
switch.sh 08-l2out           ← push the cfg onto the freshly-booted nodes
   │
(host setup commands)        ← configure host NICs, run tests
```

### Which model does each session use?

| #  | Session            | Model | Topology nodes                              | RAM¹  |
|:--:|--------------------|:-----:|---------------------------------------------|:-----:|
| 01 | underlay           |   A   | 2 spine + 2 leaf + 2 host                   | ~25GB |
| 02 | overlay            |   A   | same base                                   | ~25GB |
| 03 | l2vni              |   A   | same base                                   | ~25GB |
| 04 | anycast-gw         |   A   | same base                                   | ~25GB |
| 05a| tenant-b           |   A   | same base                                   | ~25GB |
| 05b| route-leak         |   A   | same base                                   | ~25GB |
| 06a| vpc-base           |   A   | same base (+ peer-link wiring)              | ~25GB |
| 06b| vpc-host-bond      |   A   | same base (+ host1 dual-NIC)                | ~25GB |
| 06c| vpc-vxlan          |   A   | same base                                   | ~25GB |
| 07 | ebgp-underlay      |   A   | same base                                   | ~25GB |
| 08 | l2out              |   B   | base + external + host3                     | ~30GB |
| 09 | l3out              |   B   | base + extrouter (cEOS) + host_internet     | ~32GB |
| 10 | multipod           |   B   | 4 spine + 3 leaf + IPN + hosts              | ~55GB |
| 11 | multisite          |   B   | 2 spine(=BGW) + 3 leaf + extrouter + 5 host | ~45GB |

¹ Approximate resident memory once all Nexus nodes finish booting.
Cisco N9000v needs ~5–5.5 GB each. Measure on your VM with `free -h`.

> **Rule of thumb:** advancing within 1–7? Use `switch.sh`. Jumping to
> 8, 9, 10, or 11 (or coming back to them)? Tear down and `deploy.sh`
> fresh.

> **Why some lab folders have no `topology.clab.yml`:** Model A
> sessions (05a–07) are config-push-only — they run on the base
> topology booted in 01-underlay, so they intentionally have no
> topology file of their own. (02–04 keep a copy of the base topology
> as a standalone-deploy convenience.) Model B sessions (08–11) each
> have their own self-contained topology file.

---

## The scripts

| Script             | What it does                                                            |
|--------------------|------------------------------------------------------------------------|
| `deploy.sh <s>`    | Runs `containerlab deploy` on `labs/<s>/topology.clab.yml`. Boots nodes. Does **not** push device configs (except cEOS, which loads its `startup-config` at boot). |
| `switch.sh <s>`    | Pushes `labs/<s>/configs/*.cfg` onto the already-running nodes over SSH, in parallel, and saves to startup-config. Auto-discovers nodes from the `.cfg` filenames. |
| `reset.sh <s>`     | `containerlab destroy --cleanup` then `deploy` — a clean redeploy of the same session topology. |
| `deploy-final.sh`  | Session-11 convenience wrapper: runs `switch.sh 11-multisite`, configures every host NIC, waits for convergence, and runs the 7 cross-site smoke tests. |
| `capture.sh`       | Packet capture helper (tcpdump → `.pcap` for Wireshark).               |

---

## Model A bring-up (Sessions 1–7)

Do this **once** at the start of a 1–7 study run:

```bash
cd ~/vxlan-evpn-zero-to-hero

# Boot the base fabric (one time). ~15 min for the four N9000v to pass healthcheck.
./scripts/deploy.sh 01-underlay
   # → containerlab boots spine1, spine2, leaf1, leaf2, host1, host2

# Wait until all four Nexus show healthy:
watch -n 10 'docker ps --format "{{.Names}}\t{{.Status}}" | grep clab-vxlan'
   # Ctrl-C once every n9kv says (healthy)
```

Then advance through sessions by pushing config — **no redeploy**:

```bash
./scripts/switch.sh 01-underlay     # OSPF underlay
# ...read docs/01-underlay-ospf.md, verify, break-it...

./scripts/switch.sh 02-overlay      # iBGP-EVPN overlay
# ...read docs/02-overlay-bgp-evpn.md...

./scripts/switch.sh 03-l2vni
# ...and so on through 07.
```

After each `switch.sh`, the script prints the **host-setup commands and
tests** for that session (it has a per-session block at the end). Copy
those to configure host IPs and verify.

> **If a push fails or a node is wedged**, the cleanest recovery for
> Model A is a full reset:
> `./scripts/reset.sh 01-underlay` then re-run the `switch.sh` chain up
> to where you were. N9000v single-node restarts are unreliable; prefer
> a full reset.

---

## Model B bring-up (Sessions 8, 9, 10, 11)

Each of these is self-contained. The pattern is identical for all four;
only the session name changes.

```bash
cd ~/vxlan-evpn-zero-to-hero

# 1. Tear down whatever is currently running.
#    Point destroy at the topology that is CURRENTLY up (often 01-underlay).
containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup
docker ps -a | grep clab-vxlan          # expect empty
free -h                                  # confirm RAM released

# 2. Deploy this session's self-contained topology.
./scripts/deploy.sh 08-l2out             # ← swap in 09-l3out / 10-multipod / 11-multisite
   # → boots the full fabric + this session's extra nodes

# 3. Wait for all Nexus nodes healthy.
watch -n 10 'docker ps --format "{{.Names}}\t{{.Status}}" | grep clab-vxlan'

# 4. Push configs onto the running nodes.
./scripts/switch.sh 08-l2out             # ← same session name

# 5. Configure hosts + run tests (see the per-session block switch.sh prints,
#    or the session's verify.md).
```

For **Session 11**, steps 4–5 are bundled into one convenience script:

```bash
./scripts/deploy.sh 11-multisite
# wait for healthy, then:
./scripts/deploy-final.sh                # push + host setup + 7 smoke tests
```

> **Why destroy first?** Two reasons. (1) Node-name clashes — every
> session uses the same `clab-vxlan-evpn-*` names, so a stale container
> from the previous session collides. (2) RAM — Model B sessions are
> heavier; you want the previous lab's memory freed before booting the
> next.

---

## Common gotchas

**N9000v boots slowly and the healthcheck lags.** A node can show
`unhealthy` or even briefly `exited` right after boot, then recover.
Give it 10–12 minutes before concluding it failed. Watch with
`docker logs -f clab-vxlan-evpn-spine1`.

**`switch.sh` says "X/Y NX-OS containers not running".** A node hasn't
finished booting, or a stale config folder has `.cfg` files for nodes
that don't exist in this topology. `switch.sh` discovers nodes from the
`.cfg` filenames in `labs/<s>/configs/`, so an extra file (e.g. a
leftover `bgw1.cfg`) makes it look for a container that isn't there.
Make sure `configs/` contains exactly the nodes in this session's
topology.

**Single-node `docker restart` of an N9000v often wedges it.** The
launch wrapper restarts faster than the inner NX-OS VM recovers, and it
can hang. Prefer a full `reset.sh` / destroy+deploy over restarting one
Nexus container.

**Convergence takes time after a config push.** EVPN, vPC delay-restore,
and (in Session 11) the DCI eBGP session all need 30–60 s. If a test
fails immediately after `switch.sh`, wait a minute and retest before
debugging.

**Make config changes permanent.** `switch.sh` already does
`copy running-config startup-config` at the end of each push. If you
hand-edit a device live and want it to survive a reload:

```bash
for n in spine1 spine5 leaf1 leaf2 leaf4; do
  sshpass -p admin ssh -o StrictHostKeyChecking=no \
    admin@clab-vxlan-evpn-$n 'copy running-config startup-config'
done
```

---

## Quick reference card

```
BASE FABRIC (1–7):
  deploy.sh 01-underlay         # once
  switch.sh 0X-name             # advance, no redeploy

SELF-CONTAINED (8–11):
  containerlab destroy -t labs/01-underlay/topology.clab.yml --cleanup
  deploy.sh   0X-name
  switch.sh   0X-name           # (Session 11: deploy-final.sh instead)

RECOVERY:
  reset.sh 0X-name              # destroy + redeploy same session
```
