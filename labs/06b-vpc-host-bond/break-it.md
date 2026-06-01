# Session 6b: Break-It Exercises

## Exercise 1: Bond mode mismatch — what if host uses static LAG?

LACP requires both sides to speak LACP. If the host uses static
EtherChannel (mode 0, balance-rr) but the leaf expects LACP, the
bond won't form even though links are physically up.

Simulate on host1:

```bash
docker exec clab-vxlan-evpn-host1 sh -c '
  ip link set bond0 down
  ip link delete bond0
  # Recreate bond in static round-robin mode (no LACP)
  ip link add bond0 type bond mode balance-rr miimon 100
  ip link set eth1 master bond0
  ip link set eth2 master bond0
  ip link set bond0 up
  ip addr add 10.100.10.10/24 dev bond0
  ip route replace default via 10.100.10.1
'
```

**Verify**:
```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0
```

Should show `Bonding Mode: load balancing (round-robin)`. **No LACP
negotiation field**.

On leaf1:
```
show lacp neighbor
```

Should report **no LACP neighbor on Eth1/3**.

```
show vpc
```

Should show vPC 10 status as `down` because LACP isn't negotiating.

**Restore** to LACP:
```bash
docker exec clab-vxlan-evpn-host1 sh -c '
  ip link set bond0 down
  ip link delete bond0
  ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast
  ip link set eth1 master bond0
  ip link set eth2 master bond0
  ip link set bond0 up
  ip addr add 10.100.10.10/24 dev bond0
  ip route replace default via 10.100.10.1
'
```

Wait ~30 sec for LACP to re-form.

**Lesson**: vPC member ports are configured with `channel-group X
mode active` — this forces LACP. If the host doesn't speak LACP,
the bond never comes up. Always confirm both sides speak the same
language.

## Exercise 2: One physical link is broken — bond stays up

What if eth2's physical link fails? The bond should fall back to
eth1 only.

Simulate physical failure on the leaf side:

```
ssh admin@clab-vxlan-evpn-leaf2
configure terminal
interface Ethernet1/6
shutdown
end
```

**Verify** the bond is still up on host1:
```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0
```

Should show:
- `Slave Interface: eth1` → `MII Status: up`
- `Slave Interface: eth2` → `MII Status: down`

Bond itself stays up because eth1 is healthy.

Traffic test:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
```

Should succeed. All traffic now goes via leaf1 (eth1 → leaf1).

**Restore**:
```
configure terminal
interface Ethernet1/6
no shutdown
end
```

Wait ~30 sec. Bond re-converges with both slaves up.

**Lesson**: vPC + LACP gives you per-link failure resilience. Each
slave failure is graceful — the bond keeps working, just at half
capacity until the link is restored.

## Exercise 3: Full leaf failure — both bond legs survive?

Take down leaf1 entirely. This is the production-realistic failure
scenario.

```bash
docker stop clab-vxlan-evpn-leaf1
```

**Verify** host1 is still reachable:
```bash
docker exec clab-vxlan-evpn-host1 ping -c 5 10.200.10.10
```

Hypothesis: traffic continues, slower convergence than the
interface-down case. host1's bond detects eth1's MII goes down
when leaf1 stops, falls back to eth2.

```bash
docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0
```

Expected:
- eth1 down (leaf1 is gone)
- eth2 up (leaf2 still alive)
- Bond Aggregator ID may shift because LACP partner ID changed

If ping shows >50% loss: the failover took too long. Could be:
- LACP rate is slow (30-sec timer). Confirm `lacp_rate fast` (1-sec).
- vPC consistency timer is slow. Cisco's `delay restore` is the
  recovery delay; convergence on failure is different.

**Restore**:
```bash
docker start clab-vxlan-evpn-leaf1
```

Wait ~60-90 sec for leaf1 to fully come back. NX-OS will reload
its config from startup-config (which we saved during the cfg push).
vPC will re-form, bond's eth1 slave will come back up.

If leaf1's config didn't persist (rare on snapshots), reapply:
```bash
./scripts/switch.sh 06b-vpc-host-bond
```

**Lesson**: Full leaf failure is the worst-case scenario vPC
handles. The bond stays up via the surviving leaf. Production
fabrics rely on this for chassis-level resilience. **This is the
production-essential capability we just demonstrated.**

## Exercise 4: vPC system-mac mismatch

LACP needs both leaves to advertise the same System ID. If they
don't (rare misconfig), the bond won't form correctly.

This is hard to simulate without manually overriding the vPC
system-mac. Skip unless curious — error is the same as Exercise 1's
"no LACP neighbor" symptom.

**Lesson** (read-only): vPC's `peer-switch` setting tells both
leaves to advertise the same LACP system ID. Without `peer-switch`,
each leaf advertises its own — and the host bonds with each leaf
independently rather than treating them as one peer. This is why
`peer-switch` is mandatory for vPC + LACP.

## Skip if short on time

Exercise 3 (full leaf failure) is the **most important** of these.
It's the production scenario your friends will live or die by.
The others are nice to have.
