# Homelab IaC — To Do

## You (hands-on)

- [x] Generate age key: `age-keygen -o ~/.config/sops/age/keys.txt`
- [x] Add age public key to `Hyperion/.sops.yaml`
- [x] Add SSH public key to `Hyperion/cloud-init/user-data.template.yaml`
- [x] Generate k3s token: `openssl rand -hex 32`
- [x] Add k3s token to `Hyperion/cloud-init/user-data.template.yaml`, then SOPS-encrypt it
- [x] Create dataset directories on Monolith:
  `mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/{tftp,images,kubeconfig}`
- [x] Deploy Monolith stack: `docker compose up -d` from `Monolith/k3s-control-plane/`
- [x] Copy kubeconfig to workstation and update `server:` IP to `192.168.10.247`
- [x] Remove option 67 (`bootcode.bin`) from UCG DHCP config — not used on Pi 5
- [x] Populate TFTP root with Pi 5 boot files (see runbook when written)
- [x] Create TrueNAS NFS share for netboot root filesystem at `/mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root`
- [x] Build Packer image and copy `.img` to `/mnt/App-Storage/Container-Data/k3s-control-plane/images/`
- [x] Flash cidata USB sticks (one per node) using per-node `meta-data` + `user-data.template.yaml`
- [ ] Configure EEPROM boot order on each Pi (`BOOT_ORDER=0xf416`)
- [ ] Provision nodes one at a time; run Ansible bootstrap after each
- [ ] Bootstrap FluxCD

## Repo (still to write)

- [x] Fix Packer image URL — URL confirmed valid, earlier 404 was transient
- [x] Update `Monolith/k3s-control-plane/` docker-compose with NFS mount — not needed, TrueNAS serves NFS natively
- [x] ~~Discuss node storage/partition layout~~ — resolved: see partition plan below
- [x] Netboot imaging script — `Monolith/k3s-control-plane/netboot/imaging.sh`
- [x] Netboot root filesystem setup script — `Monolith/k3s-control-plane/netboot/setup-netboot-root.sh`
- [x] `cmdline.txt` for TFTP pointing to NFS root on Monolith — `Monolith/k3s-control-plane/netboot/cmdline.txt`
- [ ] Flux bootstrap manifests (`Hyperion/k8s/flux-system/`)
- [x] Runbook: populating TFTP with Pi 5 boot files — `Monolith/k3s-control-plane/docs/runbooks/populate-tftp.md`
- [x] Runbook: setting up TrueNAS NFS share for netboot root — `Monolith/k3s-control-plane/docs/runbooks/setup-nfs-netboot.md`
- [x] Runbook: burning cidata USB sticks — `Hyperion/docs/runbooks/flash-cidata-sticks.md`
- [x] Runbook: node provisioning walkthrough — `Hyperion/docs/runbooks/provision-node.md`
- [ ] Migrate existing workloads to `Hyperion/k8s/apps/`
- [ ] Automate Packer build and image deploy (CI job: detect new Pi OS release → build → rsync to Monolith)
- [ ] Automate TFTP population (script to download image, extract boot partition, sync to Monolith)

---

## Node Storage Layout (decided)

Each node has a 256GB PCIe NVMe SSD (`/dev/nvme0n1`) partitioned as follows:

| Partition | Size | Filesystem | Mount | Purpose |
|-----------|------|------------|-------|---------|
| `nvme0n1p1` | 512MB | FAT32 | — | Pi 5 boot firmware |
| `nvme0n1p2` | 32GB | ext4 | `/` | Root OS |
| `nvme0n1p3` | ~220GB | ext4 | `/mnt/node-storage` | Node-local ephemeral storage |

**Auto-expansion of root must be suppressed** in the imaging script — the image
is flashed then partition 2 is explicitly sized to 32GB, with partition 3 carved
from the remainder.

### `/mnt/node-storage` mount logic (runs at boot via cloud-init)

- If a USB storage device (`/dev/sdX`) larger than 200GB is detected → mount it to `/mnt/node-storage`
- Otherwise → mount `nvme0n1p3` to `/mnt/node-storage`

This gives all workloads a consistent path regardless of whether a USB HDD is
present. The path is node-local and intentionally not replicated between nodes.
