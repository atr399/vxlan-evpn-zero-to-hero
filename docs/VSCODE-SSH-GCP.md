# VS Code (Windows) → GCP VM over SSH — Setup Guide

Connect Windows VS Code to the lab VM with Remote-SSH: full IDE on your
laptop, everything executes on the VM. All steps verified during the
July 2026 migration (Barrier 7 in GCP-VM-MIGRATION-GUIDE.md).

## 1. Key pair on Windows (once)

PowerShell:
```powershell
ssh-keygen -t ed25519 -C "windows-laptop"
# accept defaults -> C:\Users\YOU\.ssh\id_ed25519 (+ .pub)
type $env:USERPROFILE\.ssh\id_ed25519.pub    # copy this line
```

## 2. Authorize the key on the VM (once per VM)

SSH in any way you already can (Cloud Shell / gcloud), then:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA...paste-your-pub-line..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```
**Which home?** The one you actually work in. After a migration there
may be two user homes — put the key in the profile that owns the repos
(check `ls /home/`).

## 3. Static external IP (strongly recommended)

Default ephemeral IPs change on every VM stop/start — breaking your
saved SSH config each time.
Console → VPC network → IP addresses → Reserve external static → attach
to the VM. (Cost: free while attached to a running VM; ~$3/mo while the
VM is stopped — or release it when parking the VM long-term and update
the config on return.)

## 4. Windows SSH config

Edit `C:\Users\YOU\.ssh\config` (create if missing):
```
Host gcp-lab
    HostName <STATIC_EXTERNAL_IP>
    User <VM_USERNAME>            # e.g. netx_networking_gmail_com
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 3
```
Test from PowerShell first — always debug SSH outside VS Code:
```powershell
ssh gcp-lab
```

## 5. GCP firewall must allow SSH

Default VPCs have `default-allow-ssh` (tcp/22 from anywhere). If a
fresh project lacks it:
```bash
gcloud compute firewall-rules create allow-ssh \
  --allow=tcp:22 --direction=INGRESS --source-ranges=0.0.0.0/0
```
Hardening option: restrict `--source-ranges` to your home IP.

## 6. VS Code Remote-SSH

1. Install extension: **Remote - SSH** (ms-vscode-remote.remote-ssh).
2. `F1` → *Remote-SSH: Connect to Host* → `gcp-lab`.
3. Platform prompt: Linux. First connect installs the VS Code server on
   the VM (~1 min).
4. File → Open Folder → `/home/<user>/vxlan-evpn-zero-to-hero`.
5. Integrated terminal (Ctrl+`) now runs ON the VM — containerlab,
   docker, ssh-to-leaves all work from inside VS Code.

## 7. Troubleshooting (each hit at least once)

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | Key not in that user's authorized_keys, or wrong `User` | Re-check step 2 + username spelling (email-derived, underscores) |
| Worked yesterday, dead today | Ephemeral IP changed on VM restart | Step 3 (static IP), update `HostName` |
| Hangs at "Setting up SSH host" | VS Code server half-installed | `F1` → *Kill VS Code Server on Host* → reconnect; or `rm -rf ~/.vscode-server` on the VM |
| Connects, then drops idle | NAT timeout | `ServerAliveInterval 60` (step 4) |
| Right key, still denied | Windows key permissions or wrong profile home | `ssh -v gcp-lab` to see which key is offered; confirm the home dir |
| VM stopped | It's parked | `gcloud compute instances start ...` — and remember cost discipline: stop when done |

## 8. Daily workflow

```powershell
gcloud compute instances start vxlan-lab --zone=asia-southeast1-b   # or Console
# VS Code -> Remote-SSH -> gcp-lab -> open repo folder -> lab
# when done:
gcloud compute instances stop vxlan-lab --zone=asia-southeast1-b
```
