# Runbook: Build and Publish Node and Bootstrap Images

Hyperion nodes use two Packer-built images:

| Image | Packer template | Purpose |
|-------|----------------|---------|
| **Bootstrap IMG** | `rpi-bootstrap.pkr.hcl` | Flashed to a microSD card; boots Pi, flashes NVMe, reboots |
| **Node IMG** | `rpi-node.pkr.hcl` | The production OS, flashed to NVMe by Bootstrap |

Both are built automatically by GitHub Actions on every push to `main` that touches
`Hyperion/packer/`. For manual builds (e.g. first time before CI is configured),
use `Hyperion/publish-image.sh`.

---

## What the Node IMG contains

Starting from Raspberry Pi OS Lite 64-bit (Debian Trixie, arm64):

| What | Why |
|------|-----|
| `owner` user (sudo, no password) | Replaces the default `pi` user |
| SSH authorized key for `owner` | Key is injected at build time via `NODE_SSH_PUBLIC_KEY` variable |
| `curl`, `jq`, `git`, `nfs-common`, `open-iscsi`, `zstd` | k3s and utility dependencies |
| k3s binary (not enabled) | Pre-installed; k3s is started by Ansible post-imaging |
| cgroup kernel parameters in `cmdline.txt` | Required for k3s container resource management |
| Auto-expansion suppressed | Bootstrap handles explicit NVMe partitioning |
| `apply-identity.service` | Sets hostname from HYPERION-ID USB stick on first NVMe boot |
| `detect-node-storage.service` + `mnt-node-storage.mount` | Mounts best available storage device to `/mnt/node-storage` |
| `[pi5]` config.txt section: `kernel=kernel_2712.img`, `auto_initramfs=1`, `dtparam=pciex1_gen=3`, `dtparam=nvme` | Pi 5 NVMe boot directives. Gen 3 PCIe is overclocked (spec is Gen 2) — see comment in `rpi-node.pkr.hcl` for validated drive models. `kernel=` and `dtparam=nvme` are redundant on Trixie but kept for Bookworm compat. |
| Timezone: UTC | Consistent timestamps across all nodes |
| Version stamp in `/boot/firmware/node-img.ver` | Bootstrap uses this to decide whether to reflash |

## What the Bootstrap IMG contains

Minimal Pi OS Lite with:
- `curl`, `jq`, `parted`, `e2fsprogs`, `dosfstools`, `util-linux`, `zstd`
- `bootstrap.sh` + `hyperion-bootstrap.service` (runs on every boot)
- SSH enabled (emergency access)

---

## Prerequisites (one-time per workstation)

### Install Packer

```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y packer
packer plugins install github.com/solo-io/arm-image
```

### Install QEMU and register binfmt handlers

```bash
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

> binfmt handlers reset on reboot. Re-run the `docker run` command if builds fail
> with "exec format error".

---

## Build and publish (manual)

```bash
cd ~/GitHub/Homelab/Hyperion
export NODE_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"

# Publish Node IMG (builds, compresses, uploads, updates manifest)
./publish-image.sh node

# Publish Bootstrap IMG (builds and uploads raw .img)
./publish-image.sh bootstrap
```

**Expected duration:** ~10–15 min for Node IMG, ~5 min for Bootstrap IMG.

To build without uploading:
```bash
./publish-image.sh node --dry-run
# Output: Hyperion/packer/output/rpi-node.img
```

---

## Build and publish (CI — normal workflow)

Push any change to `main` touching these paths:

| Path | Triggers |
|------|---------|
| `Hyperion/packer/rpi-node.pkr.hcl` | Node IMG build |
| `Hyperion/packer/files/**` | Node IMG build (and Bootstrap IMG if bootstrap files changed) |
| `Hyperion/packer/rpi-bootstrap.pkr.hcl` | Bootstrap IMG build |
| `Hyperion/packer/files/bootstrap.sh` | Bootstrap IMG build |
| `Hyperion/packer/files/bootstrap.service` | Bootstrap IMG build |

CI compresses the Node IMG with `zstd -19`, uploads to Monolith, and updates
`/mnt/Media-Storage/Infra-Storage/images/node/manifest.json` automatically.

---

## When to rebuild

| Trigger | Which image |
|---------|------------|
| Raspberry Pi OS base image version updated | Both |
| Changes to `files/bootstrap.sh` or `bootstrap.service` | Bootstrap IMG |
| Changes to any other file under `files/` | Node IMG |
| k3s version update | Node IMG |
| SSH key rotation | Node IMG |

---

## Flashing the Bootstrap SD card

The ci-deploy container on Monolith decompresses the image automatically after syncing.
Download `rpi-bootstrap.img` from `http://192.168.10.247:50011/bootstrap/rpi-bootstrap.img`.

```bash
sudo dd if=rpi-bootstrap.img of=/dev/sdX bs=4M conv=fsync status=progress
# or use Balena Etcher
```

This SD card is shared across all nodes — identity comes from the per-node HYPERION-ID USB stick.
