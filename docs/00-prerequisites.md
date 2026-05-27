# Session 0: Prerequisites & Lab Platform

Before any VXLAN-EVPN content, we need a working lab platform. This session
walks you through building one from scratch.

You have two options. Pick one:

- **GCP path** — a virtual machine in Google Cloud. Costs ~$5-15/day while
  running (stop the VM when not labbing). No hardware needed. Recommended
  if you don't already have a powerful PC with virtualization.
- **Local path** — VMware Workstation or VirtualBox on your own PC. Free
  to run. Recommended if you have 32GB+ RAM and an Intel/AMD CPU with VT-x.

Both end at the same place: an Ubuntu host running Docker + containerlab +
your Cisco N9000v vrnetlab image.

---

## Goal of this session

By the end of this session you will have:

1. An Ubuntu 24.04 host (cloud or local) with nested virtualization enabled.
2. Docker installed and running.
3. Containerlab installed.
4. A vrnetlab-built `cisco_n9kv` container image, ready to launch.
5. A successful "hello world" deploy of a 2-node SR Linux lab to prove the
   plumbing works.

The Cisco image build takes the longest. The rest is plumbing.

---

## Path A — GCP setup (recommended for portability)

### A.1 Create a GCP project

If you're new to GCP:

1. Sign up at https://cloud.google.com — Google gives new accounts a $300
   trial credit, which is plenty for a few weeks of labbing.
2. Create a new project. Note the **Project ID** (different from the
   Project Name — the ID is what `gcloud` uses).
3. Enable billing on the project.

### A.2 Create the VM

The most important detail is **nested virtualization**. Cisco Nexus 9000v
is a qcow2 VM image, not a real container. vrnetlab boots it via KVM
inside a Docker container. That means the cloud VM hosting Docker must
itself expose hardware virtualization (the VMX CPU flag) to its guest OS.

GCP does **not** enable nested virtualization by default. You must set it
at VM creation time, and the machine type must support it.

**Machine type rules:**

- ✅ N2, N2D, C2, C2D series — support nested virt
- ❌ E2 series — does NOT support nested virt; do not pick this

**Recommended sizing for a 4-node fabric + 2 hosts:**

| Resource | Minimum   | Comfortable |
|----------|-----------|-------------|
| vCPU     | 8         | 12          |
| RAM      | 32 GB     | 48 GB       |
| Disk     | 60 GB     | 100 GB      |

Each Nexus 9000v node wants ~2 vCPU and ~10 GB RAM. Four nodes = 8 vCPU,
40 GB. Hosts and the OS itself need headroom on top.

**Create the VM from Cloud Shell:**

Open Cloud Shell from the GCP web console (the `>_` icon, top right).
Then:

```bash
gcloud compute instances create vxlan-lab \
  --machine-type=n2-standard-12 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=100GB \
  --enable-nested-virtualization \
  --metadata=enable-oslogin=TRUE \
  --zone=YOUR-PREFERRED-ZONE
```

Substitute a zone close to you (e.g. `asia-southeast1-b` for Singapore,
`us-central1-a` for the US Midwest, `europe-west1-b` for Belgium).

Note: we're using Ubuntu 24.04 LTS, not 26.04. 24.04 is the well-tested
LTS — fewer surprises around system services like `sudo` and `cloud-init`.

### A.3 Grant yourself sudo on the VM

OS Login is now enabled on the instance, but you also need an IAM role
that grants sudo via OS Login.

Find your IAM account:

```bash
gcloud config get-value account
```

Grant yourself the OS Admin Login role on the project:

```bash
gcloud projects add-iam-policy-binding YOUR-PROJECT-ID \
  --member="user:YOUR-EMAIL@gmail.com" \
  --role="roles/compute.osAdminLogin"
```

### A.4 SSH in and verify

From Cloud Shell or the GCP console SSH-in-browser button:

```bash
gcloud compute ssh vxlan-lab --zone=YOUR-ZONE
```

Once you're in, verify nested virtualization is exposed:

```bash
grep -cw vmx /proc/cpuinfo
```

You want a non-zero result (ideally matching your vCPU count). A `0`
means nested virt didn't take effect — go back and check the VM was
created with `--enable-nested-virtualization`.

Verify sudo works:

```bash
sudo -l
```

You should see a list of allowed commands.

---

## Path B — Local Workstation setup (alternative)

If you have VMware Workstation, VirtualBox, or Proxmox on your PC:

1. Create a VM with **Ubuntu 24.04 LTS**.
2. Allocate at least 8 vCPU, 32 GB RAM, 100 GB disk.
3. **Critical**: enable nested virtualization on the VM. In VMware
   Workstation, this is "Virtualize Intel VT-x/EPT or AMD-V/RVI" under
   VM Settings → Processors. Without this, the Cisco image build will
   hang during the first qcow2 boot inside the build container.
4. Install Ubuntu and configure a user with `sudo` access.
5. Verify with `grep -cw vmx /proc/cpuinfo` — non-zero means good.

Skip ahead to **section C** (Install Docker).

---

## C — Install Docker

Same on both paths. From the Ubuntu shell:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Log out and back in (the group change requires a fresh session). Then
verify:

```bash
docker run hello-world
```

You should see "Hello from Docker!" and a clean exit.

---

## D — Install containerlab

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
```

Add yourself to the clab admin group:

```bash
sudo usermod -aG clab_admins $USER
```

Log out and back in once more. Verify:

```bash
containerlab version
```

You should see the version banner.

### D.1 Validate the install with a quick SR Linux test

Before we touch Cisco images, prove the whole stack works with a tiny
2-node SR Linux topology. SR Linux is Nokia's container-native NOS — it
pulls from a public registry and runs without nested virt.

```bash
mkdir -p ~/clab-validation && cd ~/clab-validation

cat > srl.clab.yml << 'EOF'
name: srl-validation

topology:
  nodes:
    srl1:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:latest
    srl2:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:latest

  links:
    - endpoints: ["srl1:e1-1", "srl2:e1-1"]
EOF

containerlab deploy -t srl.clab.yml
```

First run pulls ~1 GB. When it finishes you'll see a summary table with
two `running` containers and their management IPs on the `clab` bridge
(172.20.20.0/24).

Tear it down:

```bash
containerlab destroy -t srl.clab.yml
```

If this worked, the platform is solid. Now we deal with Cisco.

---

## E — Get the Cisco Nexus 9000v image

This is the only step we can't fully automate for you. **Cisco's images
require a CCO login and acceptance of their licensing terms.** You need
to download the image yourself from cisco.com.

The image we use throughout this curriculum:

- Product: Cisco Nexus 9300v (lite)
- Version: 10.5.5 (any 10.x release works; configs are compatible)
- Filename: `nexus9300v64-lite.10.5.5.M.qcow2` (or similar)

To find it: cisco.com → Support → Downloads → Switches → Data Center
Switches → Nexus 9000 Series → Nexus 9000v.

Once you have the qcow2 on your local machine, you need to get it onto
the lab VM.

### E.1 (GCP only) Upload via GCS bucket

The browser SSH "upload file" button times out on files this large. Use
Google Cloud Storage as an intermediate:

1. From Cloud Shell, create a bucket (bucket names are globally unique,
   so add a personal suffix):

   ```bash
   gcloud storage buckets create gs://YOUR-NAME-clab-images \
     --location=YOUR-REGION \
     --uniform-bucket-level-access
   ```

2. Grant the VM's service account read access. First find the service
   account email:

   ```bash
   gcloud compute instances describe vxlan-lab \
     --zone=YOUR-ZONE \
     --format='value(serviceAccounts.email)'
   ```

   Then:

   ```bash
   gcloud storage buckets add-iam-policy-binding gs://YOUR-NAME-clab-images \
     --member="serviceAccount:THAT-EMAIL" \
     --role="roles/storage.objectViewer"
   ```

3. Upload the qcow2 via the GCS web console (Cloud Storage → Buckets →
   your bucket → UPLOAD FILES, drag from your PC). Wait for it to finish.

### E.2 (Local Workstation) Just copy the file

Use `scp` from your PC, or copy via shared folders / drag-and-drop into
the VM. Put the file in `~/Downloads` or similar.

---

## F — Build the cisco_n9kv vrnetlab image

vrnetlab is the tool that wraps a vendor qcow2 into a Docker container
running KVM internally.

### F.1 Install build dependencies and clone the repo

```bash
sudo apt update
sudo apt install -y git make build-essential
cd ~
git clone https://github.com/hellt/vrnetlab.git
cd vrnetlab/cisco/n9kv
cat README.md
```

The README confirms the expected filename format: `n9kv-<version>.qcow2`.

### F.2 Pull (or copy) the qcow2 into this folder

**GCP path:**

```bash
gcloud storage cp gs://YOUR-NAME-clab-images/nexus9300v64-lite.10.5.5.M.qcow2 \
  ./n9kv-9300-10.5.5.qcow2
```

Note the rename in the destination — we drop the `M` and reformat the
name to match vrnetlab's expected pattern.

**Local path:**

```bash
cp ~/Downloads/nexus9300v64-lite.10.5.5.M.qcow2 ./n9kv-9300-10.5.5.qcow2
```

Verify the file is there:

```bash
ls -la n9kv-9300-10.5.5.qcow2
```

You should see ~2.6 GB.

### F.3 Build

```bash
make docker-image
```

This takes 10-20 minutes the first time. What's happening:

1. vrnetlab builds a Debian base image with KVM, qemu, and Python tools.
2. Your qcow2 is copied into the build container.
3. The qcow2 is **booted** inside the container so vrnetlab can capture
   NX-OS's first-boot state. This is the step that requires your nested
   virtualization to be working — if VMX wasn't exposed, this step would
   hang or crash with a kvm-related error.
4. The booted state is snapshotted and tagged.

When done you should see:

```
naming to docker.io/vrnetlab/cisco_n9kv:9300-10.5.5
```

Verify:

```bash
docker images | grep n9kv
```

---

## G — You're done with prerequisites

If you got this far, you have:

- A host with Docker, containerlab, and a working `cisco_n9kv` image
- Validated end-to-end with SR Linux
- Understanding of where each piece fits

Now clone this curriculum and start session 1:

```bash
cd ~
git clone https://github.com/atr399/vxlan-evpn-zero-to-hero.git
cd vxlan-evpn-zero-to-hero
./scripts/deploy.sh 01-underlay
```

Open `docs/01-underlay-ospf.md` and read along with the running lab.

---

## Troubleshooting

**Symptom:** `make docker-image` hangs at "Booting NX-OS" or crashes with
KVM errors.

**Cause:** Nested virtualization isn't exposed. Check with
`grep -cw vmx /proc/cpuinfo` — must be non-zero.

**Fix (GCP):** Recreate the VM with `--enable-nested-virtualization`.
Cannot be toggled on a running instance.

**Fix (Workstation):** VM Settings → Processors → enable "Virtualize
Intel VT-x/EPT or AMD-V/RVI".

---

**Symptom:** `sudo: ... may not run sudo on ...` despite OS Login enabled.

**Cause:** The IAM role grants login but not sudo. You need the
`compute.osAdminLogin` role specifically (the *Admin* variant), not just
`compute.osLogin`.

**Fix:** Re-run the IAM binding command in section A.3. Then close your
SSH session and open a new one — IAM changes don't apply to existing
sessions.

---

**Symptom:** `gcloud storage cp ... 403 Forbidden` from the VM.

**Cause:** The VM's service account doesn't have access to the bucket,
even though you do. VMs use a service account identity, not your IAM
identity.

**Fix:** Run the IAM binding in section E.1 step 2. Make sure the
service account email matches what the error message reports.

---

**Symptom:** Cisco image build succeeds but takes ~30 minutes.

**Cause:** Normal on first build — the base image, qemu install, and
NX-OS first boot all need to happen. Subsequent builds (rebuilding
after a vrnetlab update) are much faster because Docker caches layers.

**Not actually a problem.** Be patient.
