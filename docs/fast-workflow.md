# Fast Workflow: One Bootstrap, Fast Sessions Forever

This curriculum uses a "warm baseline" pattern. You boot the NX-OS lab
once (~20 min), snapshot it, and from then on every session deploys in
~90 seconds.

## The big idea

Each session has its own cfg files (`labs/0X-session/configs/*.cfg`).
Instead of booting NX-OS fresh for each session, we:

1. **Bootstrap once**: boot a fresh "empty" NX-OS lab (no session config),
   then snapshot the running containers. Disk cost: ~22 GB, paid once.
2. **For each session**: destroy any running lab, restore the warm
   snapshot, push the session's cfg files via SSH in parallel.

Result:
- One-time setup: ~20 min
- Per-session deploy: ~90 sec
- Disk used: ~22 GB (constant, doesn't grow with new sessions)
- Sessions are independent: jump to any session at any time

## Day-one setup

```bash
# 1. Install dependencies (one-time)
sudo apt install -y sshpass

# 2. Bootstrap the warm baseline (one-time, ~20 min)
./scripts/bootstrap.sh
```

During bootstrap, four NX-OS nodes boot from cold, vrnetlab does its
first-boot config push (hostname, admin user, ssh — nothing else), then
we `docker commit` each container as `vxlan-warm:<node>`. The booted
qcow2 disk state is captured.

After this, you never wait for an NX-OS boot again until you destroy
the warm baseline.

## Day-two workflow (and every day after)

```bash
# Bring up any session in ~90 seconds
./scripts/lab.sh 01-underlay

# Tear down when done (keeps the warm baseline)
./scripts/teardown.sh

# Switch to a different session — also ~90 seconds
./scripts/lab.sh 03-l2vni
```

You can jump between any sessions in any order. Each `lab.sh` call
restores from the same warm baseline and pushes that session's cfg.
No state pollution between sessions.

## What `lab.sh` actually does

For `./scripts/lab.sh 04-anycast-gw`:

1. Destroys any currently running lab
2. Deploys 4 NX-OS containers from `vxlan-warm:*` snapshots (~30 sec)
3. Waits for all 4 to report healthy via Docker healthcheck (~30 sec)
4. SSHes into each node **in parallel** and pushes its cfg file
   (`labs/04-anycast-gw/configs/spine1.cfg` etc.) via `configure
   terminal` + cfg lines + `end` + `copy running-config startup-config`
5. Verifies a session-specific marker (e.g.,
   `fabric forwarding anycast-gateway-mac` for Session 4)
6. Reports what host IP setup commands to run

Total: ~90 sec from `lab.sh` invocation to "you can ping things".

## Host setup is still manual

The Alpine hosts (`host1`, `host2`) come up with no IPs. Each session
needs different host configuration (different VLAN, subnet, gateway).
The `lab.sh` script prints the right host commands at the end of each
deploy — copy/paste them.

We deliberately keep this manual: hosts reconfigure in 2 seconds, the
exercise of running the commands teaches what each session needs, and
it keeps `lab.sh` simple.

## Break-it recovery

If you mess up the lab during a break-it exercise:

```bash
./scripts/lab.sh 04-anycast-gw   # reset to clean Session 4 state, ~90 sec
```

That's the entire break-it recovery path. No per-session snapshots,
no resume-from-savepoint complexity. Just re-run lab.sh.

## When to re-bootstrap

You only need to re-run `bootstrap.sh` if:

- You delete the `vxlan-warm:*` images (e.g., during a docker prune)
- You upgrade the base `cisco_n9kv` image (new NX-OS version)
- The warm baseline somehow becomes corrupted (rare; you'd notice
  `lab.sh` failing to find healthy nodes)

Bootstrap is idempotent — running it again just overwrites the
existing warm images.

## Disk math

| Component                    | Size      | Permanent? |
|------------------------------|-----------|------------|
| `vrnetlab/cisco_n9kv:9300-10.5.5` (base) | ~7 GB | Yes (once) |
| `vxlan-warm:spine1` etc. (4 nodes)        | ~22 GB   | Yes (once) |
| Running containers (when lab is up)       | ~32 GB   | No, freed on teardown |

Steady-state disk used by lab tooling: ~29 GB regardless of how many
sessions exist in the curriculum.

## Troubleshooting

### "Warm baseline image not found"

Bootstrap hasn't been run. Run `./scripts/bootstrap.sh`.

### "Config OK" check fails after lab.sh

The cfg push didn't fully apply. Check `scripts/_push.log` for errors:

```bash
cat scripts/_push.log
```

Common causes:
- Syntax error in cfg file (NX-OS rejected a line) — fix the cfg
- vrnetlab still settling — wait 30 sec and re-run `lab.sh`

### sshpass fails

Make sure sshpass is installed:

```bash
sudo apt install -y sshpass
```

The default credentials are `admin/admin` (vrnetlab's hardcoded
default for cisco_n9kv).

### Want a truly fresh boot

If you suspect snapshot corruption:

```bash
# Remove warm images
docker rmi vxlan-warm:spine1 vxlan-warm:spine2 vxlan-warm:leaf1 vxlan-warm:leaf2

# Re-bootstrap
./scripts/bootstrap.sh
```
