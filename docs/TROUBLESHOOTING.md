# VXLAN-EVPN Troubleshooting Guide — Common Problems & The Layered Method

Every problem in this guide was **actually hit and fixed** during the
live 1–11 retest of this curriculum (June 2026), or is the standard
layered check that found it. Companion doc:
[`ROUTING-VERIFICATION.md`](ROUTING-VERIFICATION.md) for reading the
control plane in depth.

---

## The method: walk the stack bottom-up

A VXLAN-EVPN "ping fails" has ~7 places to die. Check in this order and
you'll never debug the overlay while the underlay is broken:

| # | Layer | One command that proves it |
|---|-------|---------------------------|
| 1 | Host NIC/bond | `docker exec <host> ip addr` + `cat /proc/net/bonding/bond0` |
| 2 | Leaf access port | `show interface Eth1/x brief` (up? reason?) |
| 3 | Underlay IGP/eBGP | `show ip ospf neighbors` / `show ip bgp summary` |
| 4 | VTEP reachability | `show ip route <remote-VTEP-lo1>` |
| 5 | BGP EVPN sessions | `show bgp l2vpn evpn summary` (Established? PfxRcd>0?) |
| 6 | Routes installed | `show l2route evpn mac evi <vlan>` / `show ip route vrf <T>` |
| 7 | NVE/data plane | `show nve peers` / capture `udp port 4789` on BOTH uplinks |

Rule of thumb from the retest: **if everything via one host fails while
other hosts work, the problem is that host's attachment (layers 1–2),
not the fabric.** If everything cross-pod/site fails, it's layer 3–4 on
the interconnect.

---

## Symptom → root cause → fix (all field-verified in this lab)

### Host attachment

| Symptom | Root cause | Fix |
|---|---|---|
| Everything via host1 fails; host2/host3 fine | host1 configured with plain IP but leaf port is a **vPC member** (`channel-group 10 mode active`) → port `suspended (no LACP PDUs)` | host1 must run the **LACP bond** setup (Sessions 6b/8/9/10/11). |
| Bond configured, still 100% loss | LACP not converged yet — false failure | **Wait ~30 s** after bond setup; readiness check: `ping <gateway>` = TTL 255. |
| First ping always loses seq 0 | ARP resolution on first packet | Normal. Use `-c 5`; judge on later packets. |
| Port shows `Internal-Fail errDisable`; shut/no-shut won't clear | Repeated link thrashing from re-running a failing host-setup paste | Don't re-run failing pastes. Reliable recovery: `reset.sh` + clean re-chain. |
| `syntax error near unexpected token ')'` on host setup | A `#` comment containing `)` inside `docker exec sh -c '...'` | Strip ALL comments from pasted blocks. |
| `sh: bridge: not found` (external switch) | Alpine has no `bridge` command; vlan-filtering method impossible | Use the **VLAN sub-interface** method (`ip link add link eth1 name eth1.50 type vlan id 50` + plain bridge). |
| `RTNETLINK answers: File exists` | Re-running a create on leftover state | Harmless, but prefer the teardown-first blocks (`ip link delete ... 2>/dev/null`). |

### vPC

| Symptom | Root cause | Fix |
|---|---|---|
| `Configuration consistency status: failed`, reason **"Secondary IP address does not match"** | The vPC VTEP secondary (VIP) IP missing/mismatched — it's a Type-1 consistency parameter | Same `ip address 10.0.1.100/32 secondary` on both leaves' loopback1 (Session 6c). |
| Member port reason says `vpc peerlink is down` but Po100 is up | Misleading message — the **consistency failure** is holding members down | Read `show vpc` consistency line; the port reason is a symptom. |
| 6b shows consistency **success** when it should fail | **Config bleed** — 6c applied earlier polluted the state | Reset + clean re-chain; don't debug a dirty lab. |

### Underlay & interconnect

| Symptom | Root cause | Fix |
|---|---|---|
| OSPF stuck in `EXCH START` on IPN/DCI | **MTU mismatch** — NX-OS 9216 vs cEOS cap 9214; DBD exchange fails | `mtu 9214` on spine IPN interfaces. **Even if config has it**: on N9000v MTU may not take effect until the interface bounces — re-apply to bounce. |
| Empty pcap though ping works | **ECMP** — flow hashed to the *other* uplink | Capture on **both** uplinks simultaneously; confirm with `show ip route <vtep>` (2 paths). |

### BGP EVPN / convergence

| Symptom | Root cause | Fix |
|---|---|---|
| All smoke tests fail right after a big push; spine shows leaves **Idle**, `MsgRcvd 0` | Tested too early — BGP still re-establishing, NVE in convergence hold-down | Wait. Readiness: leaves **Established with PfxRcd > 0** and NVE `Fabric convergence time left: 0`. Then test. |
| Route in `show bgp l2vpn evpn` but NOT in `show ip route vrf X` | RT import missing at the **VRF/IP** boundary (the non-`evpn` line) — leak half-configured | Both `route-target import X` AND `route-target import X evpn` are required. |
| Same-VLAN works, cross-VLAN dead | VRF RT mismatch between leaves (routing isolation, silent) | Compare `show run vrf` on both leaves. |
| Cross-site route points at the DCI address, not the BGW VIP | BGW re-origination not working (multisite config on BGW) | Want `via 10.0.2.100` (BGW VIP). Check `multisite border-gateway`, bgw-if loopback state, `rewrite-evpn-rt-asn` on DCI peering. |

### Platform / lab quirks

| Symptom | Root cause | Fix |
|---|---|---|
| Node stuck `(unhealthy)` forever but answers SSH | vrnetlab launcher status flag stuck at "starting" (healthcheck: `Output: "starting", ExitCode 1`, FailingStreak climbing) | **Trust SSH over the flag.** `switch.sh` uses SSH, so pushes work. Node is usable. |
| Fresh Model B deploy: cross-tenant/host tests fail mysteriously | **All hosts are blank** after destroy+deploy — including host2's Tenant-B address from Session 5a | Re-run ALL host setups every Model B deploy. Host state never survives destroy. |
| Chained sessions (Model A): a host test fails for "no reason" | Host state carried from an earlier session (e.g. host2 moved at 5a) — or the loop pushed configs without running host setups | `switch.sh` pushes device config only; host setup lines it *prints* must be run by hand. |

---

## The 60-second triage (memorize this)

```bash
# 1. Who exactly is unreachable? (isolates host-attachment vs fabric)
docker exec <src> ping -c 3 <its-own-gateway>       # fails → layers 1–2
# 2. Underlay to the remote VTEP:
ssh admin@<leaf> 'show ip route <remote-lo1>'        # missing → layer 3
# 3. Control plane state:
ssh admin@<leaf> 'show bgp l2vpn evpn summary'       # Idle/0 → wait or layer 3
# 4. Is the route actually installed where forwarding looks?
ssh admin@<leaf> 'show ip route <dst> vrf <tenant>'  # in BGP but not here → RT import
# 5. Only then touch the data plane (captures, both uplinks).
```
