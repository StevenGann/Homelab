# Runbook: Build and Deploy Packer Base Image

Builds the Hyperion base OS image from `Hyperion/packer/rpi-base.pkr.hcl` and
deploys it to Monolith's nginx image server. Every Pi node is provisioned from
this image via netboot.

---

## What the Image Contains

Starting from Raspberry Pi OS Lite 64-bit (Debian Trixie), the Packer build bakes in:

| What | Why |
|------|-----|
| SSH enabled | Allows Ansible and manual access post-boot |
| `id_ed25519.pub` in `pi` authorized_keys | Passwordless SSH from workstation |
| `cloud-init` | Reads cidata USB stick on first boot for node identity and k3s join |
| `cloud-init` NoCloud datasource configured | Tells cloud-init to read from USB, not a cloud provider |
| `curl`, `jq`, `git`, `nfs-common`, `open-iscsi` | k3s dependencies and general utilities |
| cgroup kernel parameters | Required for k3s to manage container resources |
| Auto-expand disabled | Prevents raspi-config from fighting the imaging script's partition layout |
| `/mnt/node-storage` created | Mount point for node-local storage partition |
| k3s binary pre-downloaded | Speeds up node provisioning |
| Timezone: UTC | Consistent timestamps across all nodes |

---

## Prerequisites

These only need to be set up once per workstation.

### 1. Install Packer

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y packer
```

### 2. Install the ARM image plugin

The plugin must be installed for both the regular user and root (since the build
requires `sudo`):

```bash
cd ~/GitHub/Homelab/Hyperion/packer
packer init rpi-base.pkr.hcl
sudo packer init rpi-base.pkr.hcl
```

Plugin is sourced from `github.com/solo-io/arm-image` v0.2.7+. It uses QEMU and
loopback mounts to run provisioners inside the ARM image on an x86 host.

### 3. Install QEMU and register binfmt handlers

QEMU is needed to execute ARM64 binaries during the chroot provisioning steps:

```bash
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

> The binfmt handlers are reset on reboot. If the build fails with exec format
> errors, re-run the `docker run` command above before retrying.

---

## Build

```bash
cd ~/GitHub/Homelab/Hyperion/packer
mkdir -p output
sudo packer build -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" rpi-base.pkr.hcl
```

**Expected duration:** ~7–10 minutes (downloads ~500MB image, runs all provisioners).

**Output:** `packer/output/rpi-base.img` (~4GB)

### Expected warnings (safe to ignore)

| Warning | Reason |
|---------|--------|
| `raspberrypi-sys-mods-firstboot.service does not exist` | Trixie removed this service; auto-expand is already handled by `sed` on `cmdline.txt` |
| `resize2fs_once.service does not exist` | Same as above |
| `System has not been booted with systemd as init system` | `timedatectl` doesn't work in chroot; timezone is set on first boot |

---

## Deploy to Monolith

After a successful build, copy the image to Monolith's nginx image server:

```bash
rsync -av --progress \
  output/rpi-base.img \
  truenas_admin@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/images/
```

Nginx serves this at `http://192.168.10.247:50011/rpi-base.img`, which is the URL
hardcoded in `Monolith/k3s-control-plane/netboot/imaging.sh`.

---

## When to Rebuild

Rebuild and redeploy whenever:

- The Raspberry Pi OS base image version is updated in `rpi-base.pkr.hcl`
- Packages baked into the image are changed
- The k3s binary version needs updating (currently pulled as `latest` at build time)
- Any provisioner step is modified

After rebuilding, nodes will use the new image on their next netboot provisioning cycle.

---

## Future Automation

This process is a candidate for full automation. The intended end state:

1. A CI job (e.g. GitHub Actions) detects a new Raspberry Pi OS release
2. Triggers a Packer build on a self-hosted runner with QEMU/Docker available
3. On success, rsync the new image to Monolith automatically
4. Optionally re-run `setup-netboot-root.sh` if the TFTP boot files also changed

Tracked in `docs/todo.md`.

---

## Full End-to-End Command Reference

```bash
# One-time setup
packer init rpi-base.pkr.hcl
sudo packer init rpi-base.pkr.hcl
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Build
mkdir -p output
sudo packer build -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" rpi-base.pkr.hcl

# Deploy
rsync -av --progress output/rpi-base.img truenas_admin@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/images/
```
