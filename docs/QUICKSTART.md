# Quickstart: Self-Study

This guide gets you from "fresh GCP account" to "running your own VXLAN-EVPN
lab" in about 2 hours. Most of that is the one-time bootstrap; from then
on, switching between sessions takes 10-15 seconds.

**Audience**: network engineers who know BGP and MPLS L3VPN. We assume
you're comfortable with routing concepts but maybe not with Linux/Docker
day-to-day. There's a [Linux/Docker survival doc](linux-docker-survival.md)
for the moments where the non-networking stuff trips you up.

---

## What you'll need

| Resource         | Minimum     | Recommended | Notes |
|------------------|-------------|-------------|-------|
| Cloud account    | GCP free tier | GCP with billing | AWS/Azure work too with adjustments |
| VM CPU           | 8 vCPU      | 12 vCPU     | Must support nested virtualization |
| VM RAM           | 32 GB       | 48 GB+      | More for multi-pod sessions |
| VM disk          | 60 GB       | 100 GB      | qcow2 + Docker layers add up |
| Cisco N9000v image | 10.4+ qcow2 | 10.5.5    | Requires Cisco CCO login |
| Time             | 2 hours setup + 2 hours per teaching session pair |

---

## Step 1: Spin up a GCP VM (30 minutes)

This curriculum uses Cisco Nexus 9000v, which runs as qemu/KVM inside
a container. That requires **nested virtualization** — running a VM
inside a VM. GCP supports this but you have to ask for it at VM
creation time. You cannot enable it on an existing VM.

From [Cloud Shell](https://shell.cloud.google.com):

```bash
gcloud compute instances create vxlan-lab \
  --machine-type=n2-standard-12 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=100GB \
  --enable-nested-virtualization \
  --metadata=enable-oslogin=TRUE \
  --zone=asia-southeast1-b
```

Replace the zone with one close to you (e.g., `us-central1-a`, `europe-west1-b`).

**Critical:** if you forget `--enable-nested-virtualization`, the
Cisco image build will hang during boot. You can't add this flag
later — you'd have to recreate the VM. Don't skip it.

Grant yourself sudo via IAM:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:YOUR_EMAIL@gmail.com" \
  --role="roles/compute.osAdminLogin"
```

Substitute your project ID and Gmail address.

**Reserve a static IP** (so your SSH config doesn't break every time
you stop/start the VM):

```bash
# Find the current external IP
EXTERNAL_IP=$(gcloud compute instances describe vxlan-lab \
  --zone=asia-southeast1-b \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

echo "Current IP: $EXTERNAL_IP"

# Reserve it
gcloud compute addresses create vxlan-lab-ip \
  --addresses=$EXTERNAL_IP \
  --region=asia-southeast1
```

Now your VM's IP won't change when you stop and restart it.

SSH in from Cloud Shell:

```bash
gcloud compute ssh vxlan-lab --zone=asia-southeast1-b
```

Verify nested virt is on:

```bash
grep -cw vmx /proc/cpuinfo
```

Should be `>0` (matching your vCPU count). If `0`, the VM wasn't
created with `--enable-nested-virtualization` — recreate it.

---

## Step 2: Install Docker and containerlab (10 minutes)

On the VM:

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Containerlab
bash -c "$(curl -sL https://get.containerlab.dev)"
sudo usermod -aG clab_admins $USER

# sshpass (needed for fast session switching)
sudo apt update
sudo apt install -y sshpass git make build-essential
```

**Log out and log back in** so the group memberships take effect.
Verify:

```bash
docker run hello-world          # should print "Hello from Docker!"
containerlab version            # should print version banner
groups                          # should include docker and clab_admins
```

---

## Step 3: Get the Cisco N9000v image (30-60 minutes)

This is the only step that **cannot be automated** for you. Cisco
licenses N9000v under terms that require you to download it from
your own CCO account.

1. Go to **[cisco.com](https://software.cisco.com)** → Sign in
2. **Downloads** → Switches → Data Center Switches → **Nexus 9000 Series Switches**
3. **Nexus 9000v** → version **10.5(5)** (or any 10.x — configs are compatible)
4. Download the file matching pattern `nexus9300v64-lite.10.5.5.M.qcow2`
   (the "lite" variant — smaller, faster boot, all features we need)

**Get it onto the VM** via GCS bucket (the GCP SSH "upload file"
button times out on files this large):

From Cloud Shell:

```bash
# Create a bucket (names are globally unique — add a suffix)
gcloud storage buckets create gs://YOUR_NAME-vxlan-images \
  --location=asia-southeast1 \
  --uniform-bucket-level-access

# Grant the VM's service account read access
SA_EMAIL=$(gcloud compute instances describe vxlan-lab \
  --zone=asia-southeast1-b \
  --format='value(serviceAccounts.email)')

gcloud storage buckets add-iam-policy-binding gs://YOUR_NAME-vxlan-images \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectViewer"
```

Then upload the qcow2 to the bucket via the **Cloud Storage web
console** (Cloud Storage → Buckets → your bucket → UPLOAD FILES).
Drag the file from your PC.

On the VM, pull it from the bucket:

```bash
cd ~
git clone https://github.com/hellt/vrnetlab.git
cd vrnetlab/cisco/n9kv
gcloud storage cp gs://YOUR_NAME-vxlan-images/nexus9300v64-lite.10.5.5.M.qcow2 \
  ./n9kv-9300-10.5.5.qcow2
```

Note the rename — vrnetlab expects `n9kv-<version>.qcow2`.

---

## Step 4: Build the cisco_n9kv container image (15-20 minutes)

```bash
cd ~/vrnetlab/cisco/n9kv
make docker-image
```

This wraps the qcow2 in a Docker container with qemu/KVM inside.
Takes 15-20 min the first time (uses your nested virt). When done,
verify:

```bash
docker images vrnetlab/cisco_n9kv
```

You should see `vrnetlab/cisco_n9kv:9300-10.5.5`.

---

## Step 5: Clone the curriculum repo (1 minute)

```bash
cd ~
git clone https://github.com/atr399/vxlan-evpn-zero-to-hero.git
cd vxlan-evpn-zero-to-hero
ls
```

You should see `docs/`, `labs/`, `scripts/`, etc.

---

## Step 6: Your first session (15 minutes)

This is the **only slow deploy you do per day**. After this, switching
to other sessions takes ~10 seconds each.

```bash
./scripts/deploy.sh 01-underlay
```

This boots 4 NX-OS containers in parallel. Takes 15-20 min on first
run. Go get coffee.

When done, verify Session 1 works:

```bash
ssh admin@clab-vxlan-evpn-spine1
# password: admin
```

```
show ip ospf neighbors
```

You should see 2 neighbors in `FULL/-` state. Then:

```
exit
```

Read [`docs/01-underlay-ospf.md`](01-underlay-ospf.md) alongside the
running lab to understand what each piece does.

---

## Step 7: Switch between sessions (~10 seconds each)

This is the fast workflow. The lab stays running; you push each
session's config on top:

```bash
./scripts/switch.sh 02-overlay     # adds BGP EVPN, ~10 sec
./scripts/switch.sh 03-l2vni       # adds first L2VNI, ~10 sec
./scripts/switch.sh 04-anycast-gw  # adds anycast + L3VNI, ~10 sec
```

Each `switch.sh` prints any host configuration needed for that
session. Sessions 3 and 4 need IP/route setup on host1 and host2 —
just copy/paste the printed commands.

For each session:
1. Read `docs/0X-topic.md` — explains the design and what to expect
2. Run `./scripts/switch.sh 0X-session-name`
3. SSH into devices and run commands from `labs/0X-session/verify.md`
4. Try the exercises in `labs/0X-session/break-it.md`
5. Capture packets with `./scripts/capture.sh` if you want Wireshark
   evidence

When done for the day:

```bash
./scripts/reset.sh 01-underlay  # tears down, frees RAM
```

You can also just stop the GCP VM via the console (saves money while
not running; resume takes 30 sec).

---

## Common stumbles

**"Permission denied" on Docker commands.** You need to log out
and back in after the `usermod -aG docker` step. Group membership
doesn't apply to existing shell sessions.

**"sudo: ... may not run sudo".** OS Login is on but the IAM role
isn't `compute.osAdminLogin`. Re-check Step 1's IAM binding command.
After fixing, open a new SSH session — IAM changes don't apply to
existing sessions.

**The qcow2 build hangs.** Nested virtualization isn't enabled on
the VM. `grep -cw vmx /proc/cpuinfo` should be non-zero. If `0`, the
VM has to be recreated with `--enable-nested-virtualization`.

**`switch.sh` says "SSH FAILED".** The lab isn't running, or the
NX-OS containers are still booting. Run `docker ps` to check; if
containers show `Exited`, do `./scripts/deploy.sh <session>` for a
fresh boot.

**Anything else weird** — check
[`docs/linux-docker-survival.md`](linux-docker-survival.md). It
covers the most common "the networking is fine but the Linux/Docker
side broke" situations.

---

## What's next

- **All session docs**: `docs/01-*` through `docs/11-*`
- **The break-it exercises**: in each session's `labs/0X-*/break-it.md`
- **The teaching guide**: if you want to teach this material to
  others, see `teaching/` for the lesson plans the curriculum author
  used during live sessions.

If you spot bugs, gaps, or want to contribute, open an issue or PR
on GitHub.
