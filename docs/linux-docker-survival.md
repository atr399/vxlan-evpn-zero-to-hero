# Linux/Docker Survival for Network Engineers

This curriculum runs on Linux containers driven by Docker. If you're a
network engineer who lives in NX-OS, JunOS, or IOS-XR, the Linux/Docker
layer can feel opaque. This doc covers the moments where you'll get
tripped up — not because the networking is hard, but because Linux is
behaving in a way you didn't expect.

This isn't a Linux tutorial. It's a "the next time X confuses you,
here's the answer" reference.

---

## Docker basics for the lab

### "Show me what's running"

```bash
docker ps              # currently running containers
docker ps -a           # all containers, including stopped ones
```

In our lab, you should see 6 containers when active:
- 4 NX-OS nodes: `clab-vxlan-evpn-spine1`, `spine2`, `leaf1`, `leaf2`
- 2 hosts: `clab-vxlan-evpn-host1`, `host2`

### "What's a container 'doing' right now"

```bash
docker logs clab-vxlan-evpn-spine1            # show the container's stdout/stderr
docker logs -f clab-vxlan-evpn-spine1         # follow live (Ctrl+C to stop)
docker logs --tail 50 clab-vxlan-evpn-spine1  # last 50 lines
```

This is invaluable for NX-OS — vrnetlab logs its boot process here,
including the scrapli session that pushes startup config. If a node
"isn't coming up," `docker logs` shows you why.

### "Get a shell inside an Alpine host"

```bash
docker exec -it clab-vxlan-evpn-host1 sh
```

Once inside:

```sh
ip addr           # equivalent to "show ip interface brief"
ip route          # equivalent to "show ip route"
arp -n            # equivalent to "show ip arp"
ping <target>     # the same ping you know
exit              # back to the VM shell
```

Alpine is a stripped-down Linux. `ifconfig` doesn't exist by default;
use `ip` commands instead. `traceroute` isn't installed; use
`tracepath` or install with `apk add traceroute`.

### "Run a command inside a host without entering it"

```bash
docker exec clab-vxlan-evpn-host1 ip addr show eth1
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11
```

This is what you'll do most often — quick check or quick test
without needing an interactive shell.

### "I broke the lab somehow"

```bash
cd ~/vxlan-evpn-zero-to-hero
./scripts/reset.sh 01-underlay      # destroys and redeploys
```

Or to start over completely:

```bash
docker stop $(docker ps -q)         # stop everything (across all labs)
./scripts/deploy.sh 01-underlay      # fresh boot
```

---

## The two networks inside the lab

This trips people up. Every container has **two** network interfaces:

| Interface | What it's for                              |
|-----------|-------------------------------------------|
| `eth0`    | Docker management bridge (172.20.20.0/24) |
| `eth1+`   | Lab links (configured per topology)        |

So when host1 has IP `10.100.10.10/24` on eth1, it also has
`172.20.20.X/24` on eth0. That eth0 has a default route via the
Docker bridge.

**Why this matters:** if you `ip route add default via 10.100.10.1
dev eth1`, it silently fails — eth0 already has a default route.
You need `ip route replace default via 10.100.10.1` to **overwrite**
the existing default.

This is the one Docker quirk that bit us hardest while building
Session 4. Now you know.

---

## SSH gotchas

### "Why is my SSH session dropping?"

GCP VMs aggressively kill idle SSH connections. Two fixes:

In your `~/.ssh/config` on Windows/Mac, add:

```
Host gcp-vxlan-lab
    HostName <your-static-IP>
    User <your-os-login-username>
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60      # send keepalive every 60 sec
    ServerAliveCountMax 3       # disconnect after 3 missed (3 min total)
```

The `ServerAliveInterval` keeps the connection awake even when idle.

### "VS Code Remote-SSH stopped working after I stopped the VM"

By default, GCP gives stopped VMs a **new external IP** when they
start. Your SSH config has the old IP cached.

Two fixes:

**Quick fix** — update `~/.ssh/config` to the new IP each time.

**Permanent fix** — reserve a static IP from Cloud Shell:

```bash
gcloud compute addresses create vxlan-lab-ip \
  --addresses=<current-IP> \
  --region=<your-region>
```

This locks the current IP to your VM forever.

### "ssh admin@clab-vxlan-evpn-spine1 says Connection reset by peer"

The container is running but NX-OS sshd inside isn't ready yet.
Either:
- It just booted — wait 30-60 sec and retry
- The qcow2 didn't recover cleanly — check `docker logs` for errors

If `docker logs` shows vrnetlab waiting on a prompt that never came,
the NX-OS state is wedged. `docker restart <container>` sometimes
fixes it; otherwise destroy and redeploy.

---

## Container vs. NX-OS — who am I talking to?

This confuses people. Think of it as two layers:

```
+-------------------------------------------+
| Docker container "clab-vxlan-evpn-spine1" |
|  +-----------------------------------+    |
|  | qemu VM running NX-OS             |    |
|  | + sshd listening on the VM IP     |    |
|  +-----------------------------------+    |
|  + vrnetlab launcher Python process       |
+-------------------------------------------+
```

- `docker exec clab-vxlan-evpn-spine1 ...` → **runs a command in the
  container**, NOT inside NX-OS. You'd see vrnetlab's shell, not
  NX-OS CLI.
- `ssh admin@clab-vxlan-evpn-spine1` → **goes through the container's
  network namespace to sshd inside the NX-OS VM**. This is how you
  reach NX-OS.

For NX-OS commands (`show ip ospf neighbors` etc.), always use SSH.
`docker exec` for NX-OS is useless — that's the container's busybox
shell, not NX-OS.

---

## Disk and memory

### "How much disk am I using?"

```bash
df -h /                # overall VM disk usage
docker system df       # Docker's specific usage
docker images          # all images, sizes
```

The base `vrnetlab/cisco_n9kv` image is ~6 GB. Plus Docker overhead,
plus session pcaps if you've taken any. Typical lab usage: ~10 GB.

### "Free up disk"

Safe commands:

```bash
docker image prune -f        # remove dangling (untagged) images only
docker container prune -f    # remove stopped containers
```

Dangerous (only run if you know what you're doing):

```bash
docker system prune -af      # removes ALL unused images, including
                             # ones not currently in a running container
```

The `-af` form will delete your `vrnetlab/cisco_n9kv` image if no
container is using it at the moment. You'd then have to rebuild it
(~15 min). Avoid unless you know what's safe to lose.

### "How much memory is each container using?"

```bash
docker stats              # live view, Ctrl+C to exit
docker stats --no-stream  # one-shot snapshot
```

Each NX-OS container takes ~8 GB RAM. Four nodes = ~32 GB. On the
recommended n2-standard-12 (94 GB), you have lots of headroom.

---

## File access and editing

### "I need to edit a file in the repo"

If you're SSHed into the VM via terminal:

```bash
sudo apt install -y nano vim     # if neither is installed
nano docs/00-prerequisites.md
```

Better: use **VS Code Remote-SSH**. Open the repo as a folder in VS
Code, edit files locally-feeling, save → changes go directly to the
VM.

### "I want to download a pcap or log to my PC"

In VS Code Remote-SSH:
1. Right-click the file in the explorer
2. Select "Download..."
3. Choose where on your PC

Or from your PC's terminal:

```bash
gcloud compute scp vxlan-lab:/path/to/file.pcap ./local-file.pcap \
  --zone=asia-southeast1-b
```

---

## What's _push.log?

When `./scripts/switch.sh` runs, it pipes each NX-OS node's config
push through SSH. The output goes to `scripts/_push.log`. If a
switch fails or the verify step says "marker missing," `_push.log`
shows exactly what each node received and how it responded.

```bash
cat scripts/_push.log         # full log
grep -i error scripts/_push.log  # just the errors
```

This file is overwritten on every `switch.sh` invocation. It's
runtime state, not source — gitignored.

---

## The mental model that helps

For a network engineer used to physical switches, the abstraction
shift is:

| Physical world         | Lab world                          |
|------------------------|------------------------------------|
| Switch in a rack       | Docker container running vrnetlab  |
| Console port           | `docker logs` (read-only)          |
| Management port (mgmt0) | Container's external interface    |
| Out-of-band SSH        | `ssh admin@clab-...`               |
| Power cycle            | `docker restart <container>`       |
| Replace switch         | `docker rm <container>` + redeploy |
| Lab cable               | A virtual veth pair                |

Once you map your existing knowledge onto these analogies, the
Linux/Docker side stops feeling weird and starts feeling like a
familiar tool with a different interface.
