# Snapshots: Fast Session Restore

After verifying a session works, you can snapshot the running lab so
that future restores take ~30 seconds instead of 15-20 minutes.

## When to use snapshots

**Use snapshots for:**
- Re-running break-it exercises (break, verify failure, restore to clean)
- Coming back to a session tomorrow without rebooting NX-OS
- Demoing a session for friends without making them wait for boot
- Hopping between sessions during development of new ones

**Don't use snapshots for:**
- First-time deployment (you need a clean boot to verify the cfg files)
- Anyone running the curriculum for the first time (they should
  experience the full deploy at least once)
- Sharing the lab — snapshots are local Docker images, not committed
  to git

## The basic workflow

```bash
# 1. Deploy a session fresh (slow, ~15-20 min)
./scripts/deploy.sh 04-anycast-gw

# 2. Verify it works end-to-end
ssh admin@clab-vxlan-evpn-leaf1  # ... run verify.md checks
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.10  # cross-subnet works

# 3. Snapshot the working state
./scripts/snapshot.sh 04-anycast-gw

# 4. Later (after break-it, after lab reboot, etc.) - fast restore
./scripts/restore.sh 04-anycast-gw   # ~30 sec
```

## What snapshot.sh actually does

1. Verifies all four NX-OS containers are `healthy` (refuses to snapshot
   a broken lab)
2. Saves `running-config` to `startup-config` on each device (so the
   qcow2 has the latest state)
3. Runs `docker commit` on each container, tagging the result as
   `vxlan-snapshot-<session>:<node>`
4. Generates `labs/<session>/topology-snapshot.clab.yml` that uses
   these images instead of the base vrnetlab image

## What restore.sh actually does

1. Destroys whatever lab is currently running
2. Deploys from the snapshot topology (uses the committed images)
3. Waits for all 4 NX-OS nodes to report healthy (typically 30-60 sec)
4. Verifies a session-specific config marker is present
5. If the marker is missing (vrnetlab sometimes wipes config on resume),
   automatically re-pushes the original cfg files via SSH

## Disk usage

Each snapshot is ~2-3 GB per NX-OS node, so ~10 GB per session. To
check what you've used:

```bash
./scripts/snapshot-list.sh
```

To remove a snapshot you don't need anymore:

```bash
docker rmi $(docker images vxlan-snapshot-04-anycast-gw* -q)
```

You have plenty of disk (~91 GB free). You can comfortably keep
snapshots for every session simultaneously.

## Important caveats

**Snapshots don't include host config.** The Alpine hosts (host1, host2)
are NOT snapshotted — they always come up fresh with no IPs. The
`restore.sh` script reminds you what host commands to re-run after
restoration. Why: hosts are tiny and reconfigure in 2 seconds; not
worth the complexity.

**Snapshots are local-only.** They live in `/var/lib/docker` on this
VM. They are NOT in the git repo and NOT pushed to any registry. If
you destroy the VM, the snapshots are gone.

**Snapshots don't survive Docker daemon reset.** If you `systemctl
restart docker` or upgrade Docker, the snapshot images persist.
However, if you wipe `/var/lib/docker`, they're gone.

**Snapshots are session-specific.** A Session 4 snapshot can only
restore the Session 4 lab. You cannot "patch" a Session 4 snapshot
to become a Session 5 lab — for that, deploy Session 5 fresh, then
snapshot it.

## Troubleshooting

### Snapshot was created but restore says config is missing

vrnetlab sometimes re-applies the original first-boot config on
container start, which wipes session config. `restore.sh` detects this
and re-pushes the cfg files automatically. You'll see:

```
WARNING: Session marker 'X' NOT found on Y.
vrnetlab may have wiped the config on resume. Re-pushing from cfg files...
```

This adds ~30 seconds to the restore but produces a working lab.

### `docker commit` is slow

Normal for the first snapshot of a session. Docker has to copy the
container's writable layer (containing the running qcow2 state) to a
new image. Subsequent commits of the same session (if you re-snapshot)
are faster due to layer caching.

### Out of disk

Run `./scripts/snapshot-list.sh` and delete the snapshots you don't
need:

```bash
docker rmi $(docker images vxlan-snapshot-<old-session>* -q)
docker system prune  # also frees dangling layers
```
