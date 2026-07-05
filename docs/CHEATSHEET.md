# Lab Runbook Cheatsheet — All Sessions (verified workflow)

One page. Follow top to bottom. Everything here matches the retest-verified behavior.

---

## The two models

| Model | Sessions | Workflow |
|---|---|---|
| **A — chain** | 01→07, 12 | ONE base deploy, then `switch.sh` per session on the running lab |
| **B — fresh** | 08, 09, 10, 11 | destroy + `deploy.sh <session>` per session (own topology) |

**Model A** = fast iteration (config push ~60s). **Model B** = 15–20 min boot each.

---

## Model A — the base + chain

```bash
cd ~/vxlan-evpn-zero-to-hero
./scripts/reset.sh 01-underlay          # destroy + fresh 4-node base (~15 min)
watch -n 10 'docker ps --format "{{.Names}}\t{{.Status}}" | grep clab-vxlan'
# all (healthy) → chain in order, ONE at a time:
./scripts/switch.sh 01-underlay
./scripts/switch.sh 02-overlay
./scripts/switch.sh 03-l2vni            # + host setup it prints
./scripts/switch.sh 04-anycast-gw       # + host setup
./scripts/switch.sh 05a-tenant-b        # + host setup (host2 MOVES to 10.200.10.10)
./scripts/switch.sh 05b-route-leak
./scripts/switch.sh 06a-vpc-base
./scripts/switch.sh 06b-vpc-host-bond   # + host1 BOND (see golden rules)
./scripts/switch.sh 06c-vpc-vxlan
./scripts/switch.sh 07-ebgp-underlay    # expect 30–60s convergence blip
```
Session 12 (DHCP): chain 01→04 only, then push `labs/12-dhcp-relay/configs/*.cfg`,
host2 = Kea server (install BEFORE fabric route!), host1 = udhcpc client.

## Model B — per session

```bash
containerlab destroy -t labs/<CURRENT>/topology.clab.yml --cleanup   # point at what's RUNNING
free -h                                  # 08/09 ~35GB, 10/11 ~55GB needed
./scripts/deploy.sh 08-l2out             # or 09-l3out / 10-multipod / 11-multisite
# wait healthy, then:
./scripts/switch.sh 08-l2out             # (11 uses ./scripts/deploy-final.sh instead)
# then ALL host setups — fresh deploy = every host blank
```

---

## GOLDEN RULES (each one cost us real debugging time)

1. **host1 = LACP bond in 6b and EVERY Model B session (8/9/10/11).**
   Plain IP → leaf port `suspended (no LACP PDUs)` → host1 dead.
   Signature: everything via host1 fails, other hosts fine.
2. **Wait 30s after the bond** before testing (false 100% loss otherwise).
   Ready-check: `host1 ping 10.100.10.1` → TTL 255.
3. **Paste host-setup blocks ONCE, comment-free.** A `#` with `)` breaks
   `sh -c`. If a paste errors: fix it, don't re-run blindly (→ errDisable,
   which shut/no-shut will NOT clear; recovery = reset + re-chain).
4. **Model B wipes ALL host state.** Re-do every host, every deploy.
5. **Session 10: re-apply `mtu 9214`** on spine1-4 Ethernet1/3 after deploy
   (config has it; needs the bounce). Gate: IPN OSPF 4× FULL before tests.
6. **Session 11: WAIT for convergence** before smoke tests — spine leaves
   must be Established with PfxRcd>0 and NVE `convergence time left: 0`.
7. **`(unhealthy)` but answers SSH = usable.** vrnetlab launcher flag lies;
   `switch.sh` uses SSH anyway.
8. **First ping loses seq 0** (ARP). Judge on `-c 5`.
9. **Host packages: install BEFORE fabric host-setup**, or flip default to
   eth0 for `apk`, then flip back.
10. **NEVER `reload` an N9000v.** Fresh deploy instead.

---

## Per-session pass criteria (the one number to check)

| Session | The test | Pass |
|---|---|---|
| 01 | leaf1 `show ip route 10.0.1.22` | 2 ECMP paths, OSPF |
| 02 | leaf `show bgp l2vpn evpn summary` | 2 spines Established, PfxRcd 0 (correct!) |
| 03 | host1 → 10.100.10.11 | **TTL 64** (bridged) |
| 04 | host1 → 10.100.20.10 | **TTL 62** (routed ×2) |
| 05a | host1 → 10.200.10.10 | **FAILS** (isolation = the lesson) |
| 05b | same ping | works, **TTL 63** (leak) |
| 06b | leaf1 `show vpc` | consistency **failed**: "Secondary IP address does not match" (intended!) |
| 06c | `show vpc` + ping | success, vPC 10 up, NVE **VPC-VIP-Only** |
| 07 | `show ip route 10.0.1.22` + cross-tenant ping | via **bgp** ext; TTL 63 |
| 08 | host1→host3, host2→host3 | TTL 63 both (external bridge = VLAN **sub-interface**, not `bridge` cmd) |
| 09 | 4 paths host1/host2 ↔ 203.0.113.10 | TTL 62 all |
| 10 | host1→host4 / host4→ext / ext→host4 | TTL 62 / 61 / 61; latency 10–18ms = IPN |
| 11 | host1↔host5, host5→ext | TTL 61/61/60; leaf1 route via **10.0.2.100** (BGW VIP = stitching) |
| 12 | udhcpc on host1 | the word **"obtained"**; leaf1 relay stats Ack ≥ 1 |

---

## 60-second triage (when any ping fails)

```bash
docker exec <src> ping -c 3 <own-gateway>            # fails → host attachment (bond? port?)
ssh admin@<leaf> 'show ip route <remote-VTEP-lo1>'    # missing → underlay
ssh admin@<leaf> 'show bgp l2vpn evpn summary'        # Idle/0 → wait or underlay
ssh admin@<leaf> 'show ip route <dst> vrf <tenant>'   # in EVPN but not here → RT import
# data plane last: capture udp 4789 on BOTH uplinks (ECMP!)
```
Full table: `docs/TROUBLESHOOTING.md`.

---

## Shutdown / cost

```bash
containerlab destroy -t labs/<CURRENT>/topology.clab.yml --cleanup
# then stop the VM (pay only disk):
gcloud compute instances stop instance-20260527-113611 --zone=<zone>
```
