# Homelab IaC — To Do

## Status

The repo is implementation-complete. All Packer builds, CI workflows, and operator
scripts are written. The steps below are what remain before nodes can be imaged.

---

## Step 1 — Commit and push

```bash
cd ~/GitHub/Homelab
git add .
git commit -m "feat: implement two-image IaC for Hyperion nodes"
git push
```

Pushing triggers GitHub Actions to build both images automatically — but CI will
fail until the secrets in Step 2 are configured. Run `publish-image.sh` locally
(Step 4) to get images built before CI is ready.

---

## Step 2 — Configure GitHub Actions secrets

In the repo Settings → Secrets → Actions, add:

| Secret | Value |
|--------|-------|
| `MONOLITH_HOST` | `192.168.10.247` |
| `MONOLITH_HOST_KEY` | Output of `ssh-keyscan 192.168.10.247` |
| `MONOLITH_SSH_KEY` | Private key for the CI deploy key (generate below) |
| `NODE_SSH_PUBLIC_KEY` | SSH public key to bake into Node IMGs (e.g. `~/.ssh/id_ed25519.pub`) |

Generate the CI deploy key (run once):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/hyperion-ci-deploy -N "" -C "hyperion-ci"
# MONOLITH_SSH_KEY = contents of ~/.ssh/hyperion-ci-deploy
# Install the public key on Monolith (Step 3)
```

---

## Step 3 — One-time Monolith setup

```bash
ssh truenas_admin@192.168.10.247

# Create image directories
mkdir -p /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}

# Create kubeconfig output directory
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig
```

Create the `.env` file in the compose directory:

```bash
cd /mnt/App-Storage/Container-Data/k3s-control-plane

# k3s cluster token
echo "K3S_TOKEN=$(openssl rand -hex 32)" >> .env

# Public key for the CI deploy key (derive from the private key on your workstation)
# Run on workstation: ssh-keygen -y -f ~/.ssh/hyperion-ci-deploy
echo "CI_PUBLIC_KEY=<paste public key here>" >> .env
```

Start the stack via Dockge (pulls `ghcr.io/stevengann/homelab-ci-deploy:latest` automatically):

```bash
docker compose up -d
```

See `Monolith/k3s-control-plane/docs/runbooks/preflight.md` for full details.

---

## Step 4 — Build and publish images (first time)

If CI is not ready yet, build locally:

```bash
cd ~/GitHub/Homelab/Hyperion
export NODE_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./publish-image.sh bootstrap
./publish-image.sh node
```

Once secrets are set, any push to `main` touching the Packer files will trigger
CI builds automatically.

---

## Step 5 — Configure EEPROM on nodes

Run while nodes are reachable (booted from any OS, SSH user `pi` or `owner`):

```bash
cd ~/GitHub/Homelab/Hyperion
./configure-eeprom.sh --reboot
```

Sets `BOOT_ORDER=0xf61` (SD → NVMe → loop) on all 10 nodes. This is safe to run
on nodes already running from NVMe — EEPROM lives in SPI flash, unaffected by
re-imaging.

---

## Step 6 — Flash identity USB sticks

One per node. Plug each USB stick in, then:

```bash
cd ~/GitHub/Homelab/Hyperion
./flash-identity-usb.sh /dev/sdX hyperion-alpha
./flash-identity-usb.sh /dev/sdX hyperion-beta
# ... repeat for all 10 nodes
```

Each stick gets: FAT32 label `HYPERION-ID`, a `hostname` file, and an empty
`node-image/` cache directory that bootstrap populates on first run.

---

## Step 7 — Flash Bootstrap SD card

Flash once; this SD card is shared across all 10 nodes during imaging:

```bash
# Download rpi-bootstrap.img from Monolith, or use Hyperion/packer/output/rpi-bootstrap.img
sudo dd if=rpi-bootstrap.img of=/dev/sdX bs=4M conv=fsync status=progress
```

---

## Step 8 — Image nodes (one at a time or all at once)

For each node:
1. Insert identity USB (HYPERION-ID, hostname written)
2. Insert Bootstrap SD card
3. Power on

Bootstrap will:
- Fetch latest Node IMG from Monolith into USB cache (if network reachable)
- Flash NVMe from USB cache
- Resize p2 → 32 GiB, create p3 (~220 GiB ext4, label `node-storage`)
- Reboot into NVMe automatically

Monitor via serial cable (ttyAMA10, 115200 baud) or:
```bash
# After USB is accessible from another machine:
tail -f <usb-mount>/node-image/bootstrap.log
```

4. Once node boots into NVMe → remove Bootstrap SD card (identity USB stays in)

---

## Step 9 — Verify SSH and run Ansible

```bash
# Spot-check SSH
ssh owner@192.168.10.101   # hyperion-alpha

# Run bootstrap playbook against all nodes
cd ~/GitHub/Homelab/Hyperion/ansible
ansible-playbook -i inventory bootstrap.yml
```

---

## Step 10 — k3s and FluxCD

- [ ] Install and configure k3s (runbook TBD)
- [ ] Bootstrap FluxCD
- [ ] Migrate existing workloads to `Hyperion/k8s/apps/`

---

## Re-imaging a node (ongoing)

```bash
# 1. Insert Bootstrap SD card into target node
# 2. Trigger reboot:
cd ~/GitHub/Homelab/Hyperion
./reimage.sh hyperion-alpha     # or: ./reimage.sh all

# Bootstrap handles the rest automatically.
# 3. Remove Bootstrap SD after node is back on NVMe.
```

CI publishes a new Node IMG automatically on every push to `main` that touches
`Hyperion/packer/rpi-node.pkr.hcl` or `Hyperion/packer/files/**`.

---

## Node Storage Layout

| Partition | Size | FS | Mount | Purpose |
|-----------|------|----|-------|---------|
| `nvme0n1p1` | 512 MB | FAT32 | — | Pi 5 boot firmware |
| `nvme0n1p2` | 32 GB | ext4 | `/` | Root OS |
| `nvme0n1p3` | ~220 GB | ext4 | `/mnt/node-storage` | Node-local ephemeral storage |

`/mnt/node-storage` mount logic (via `detect-node-storage.service`):
- USB stick labeled `node-storage-usb` → use it
- Any USB block device >200 GB → use its first partition
- Otherwise → use `nvme0n1p3`
