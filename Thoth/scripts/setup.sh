#!/usr/bin/env bash
# Thoth — host bootstrap (run ON Thoth). Idempotent.
#
# Mirrors Heimdall/scripts/setup.sh. Brings a clean Ubuntu 26.04 install to the
# point where the Compose stack (docker-compose.yml) can run with GPU access:
#   - Docker CE (official repo) + compose plugin
#   - NVIDIA driver (open 595-server) + nvidia-smi
#   - NVIDIA Container Toolkit + docker nvidia runtime
#   - nfs-common (for the future Tdarr worker mounts)
#   - /etc/docker/daemon.json from hostconf/
#
# Storage (ZFS pools tank/fast + the Intel-SSD docker data-root) is DESTRUCTIVE
# and is NOT run by default — pass --provision-storage on a fresh box only.
# As-built layout (2026-06-03):
#   tank  raidz1 (sda,sdc,sdd,sdf 4×1TB HDD)  -> /tank  (models; tank/ollama)
#   fast  single (sde Samsung 960G SSD)        -> /fast  (game servers)
#   Intel 240G SSD (sdb) ext4                  -> /var/lib/docker (data-root)
set -euo pipefail
log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }

PROVISION_STORAGE=0
[ "${1:-}" = "--provision-storage" ] && PROVISION_STORAGE=1

# ─── base packages ───────────────────────────────────────────────────────────
log "Base packages..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg jq git age python3 nfs-common zfsutils-linux

# ─── Docker CE (official repo, codename fallback for brand-new releases) ──────
log "Docker CE..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
CN="$(. /etc/os-release; echo "$VERSION_CODENAME")"
curl -fsI "https://download.docker.com/linux/ubuntu/dists/$CN/Release" >/dev/null 2>&1 || { log "Docker repo lacks $CN; using noble"; CN=noble; }
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CN stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
id owner >/dev/null 2>&1 && sudo usermod -aG docker owner || true

# ─── daemon.json (nvidia runtime is merged in below by nvidia-ctk) ───────────
log "docker daemon.json..."
sudo install -d -m 0755 /etc/docker
sudo install -m 0644 "$(dirname "$0")/../hostconf/docker-daemon.json" /etc/docker/daemon.json

# ─── NVIDIA driver (open 595-server) + nvidia-smi ────────────────────────────
log "NVIDIA driver..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nvidia-headless-no-dkms-595-server-open nvidia-utils-595-server || sudo ubuntu-drivers install --gpgpu || true
command -v nvidia-smi >/dev/null && nvidia-smi -L || log "WARN: nvidia-smi not ready (reboot may be needed)"

# ─── NVIDIA Container Toolkit + docker runtime ───────────────────────────────
log "NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# ─── storage (DESTRUCTIVE — fresh box only) ──────────────────────────────────
if [ "$PROVISION_STORAGE" -eq 1 ]; then
    if zpool list tank >/dev/null 2>&1 || zpool list fast >/dev/null 2>&1; then
        log "tank/fast already exist — refusing to re-provision (remove --provision-storage)."
    else
        log "Provisioning ZFS pools (WIPES sda,sdb,sdc,sdd,sde,sdf)..."
        for d in sda sdb sdc sdd sde sdf; do sudo wipefs -aq /dev/${d}1 2>/dev/null || true; sudo wipefs -aq /dev/$d 2>/dev/null || true; done
        sudo zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -m /tank tank raidz1 /dev/sda /dev/sdc /dev/sdd /dev/sdf
        sudo zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -m /fast fast /dev/sde
        for P in tank fast; do sudo zpool export $P; sudo zpool import -d /dev/disk/by-id $P; done
        sudo zfs create tank/ollama
        sudo mkfs.ext4 -F -q -L docker /dev/sdb
        sudo mkdir -p /var/lib/docker
        grep -q 'LABEL=docker' /etc/fstab || echo 'LABEL=docker /var/lib/docker ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab >/dev/null
        sudo mount /var/lib/docker 2>/dev/null || true
        sudo systemctl enable zfs-import-cache.service zfs-mount.service zfs.target zfs-import.target
    fi
fi

# ─── GPU-in-container smoke test ─────────────────────────────────────────────
log "GPU smoke test..."
sudo docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi -L || log "WARN: GPU smoke test failed"
log "Done. Bring up the stack: cd /opt/Homelab/Thoth && docker compose up -d"
