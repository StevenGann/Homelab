#!/usr/bin/env bash
# setup-netboot-root.sh
# Builds the Hyperion netboot root filesystem and deploys it to Monolith.
# Run from your workstation. Requires Docker with buildx and ARM64 support.
#
# Usage: ./setup-netboot-root.sh
set -euo pipefail

MONOLITH="192.168.10.247"
MONOLITH_USER="truenas_admin"
NETBOOT_PATH="/mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root"
TFTP_PATH="/mnt/App-Storage/Container-Data/k3s-control-plane/tftp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup() {
    echo "[*] Cleaning up work directory..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() { echo "[$(date '+%T')] $*"; }

log "=== Hyperion Netboot Root Setup ==="
log "Work dir: $WORK_DIR"

# ── Prerequisites ─────────────────────────────────────────────────────────────
log "Checking prerequisites..."
if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: docker buildx not found. Install Docker Desktop or docker-buildx-plugin."
    exit 1
fi
log "  docker buildx: OK"

# Register QEMU binfmt handlers for ARM64 cross-build
log "Registering QEMU binfmt handlers for ARM64..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
log "  QEMU handlers registered."

# ── Build Alpine ARM64 rootfs ─────────────────────────────────────────────────
log "Building Alpine Linux arm64 rootfs with imaging tools..."
docker buildx build \
    --platform linux/arm64 \
    --output "type=tar,dest=$WORK_DIR/rootfs.tar" \
    - <<'DOCKERFILE'
FROM alpine:latest
RUN apk add --no-cache \
    bash \
    curl \
    parted \
    e2fsprogs \
    e2fsprogs-extra \
    util-linux \
    blkid \
    busybox-extras
DOCKERFILE

log "Extracting rootfs..."
mkdir -p "$WORK_DIR/rootfs"
tar -xf "$WORK_DIR/rootfs.tar" -C "$WORK_DIR/rootfs"
log "Alpine arm64 rootfs ready."

# ── Create /init (PID 1) ──────────────────────────────────────────────────────
log "Writing /init script..."
cat > "$WORK_DIR/rootfs/init" << 'INIT'
#!/bin/sh
# PID 1 — minimal init for Hyperion netboot imaging environment

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Redirect all output to console (visible on KVM)
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo ""
echo "============================================="
echo "  Hyperion Netboot Imaging Environment"
echo "  Alpine Linux (arm64)"
echo "============================================="
echo ""

# Bring up ethernet
echo "[init] Bringing up eth0..."
ip link set eth0 up

# Obtain DHCP lease
echo "[init] Requesting DHCP lease..."
udhcpc -i eth0 -q -s /etc/udhcpc/default.script

echo "[init] Network configured:"
ip addr show eth0

# Hand off to imaging script
echo "[init] Starting imaging script..."
exec /usr/local/bin/imaging.sh
INIT
chmod +x "$WORK_DIR/rootfs/init"
log "  /init written."

# ── Minimal udhcpc script ─────────────────────────────────────────────────────
log "Writing udhcpc default script..."
mkdir -p "$WORK_DIR/rootfs/etc/udhcpc"
cat > "$WORK_DIR/rootfs/etc/udhcpc/default.script" << 'UDHCPC'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ;;
    bound|renew)
        ip addr add "$ip/$mask" dev "$interface"
        [ -n "$router" ] && ip route add default via "$router"
        [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
        ;;
esac
UDHCPC
chmod +x "$WORK_DIR/rootfs/etc/udhcpc/default.script"
log "  udhcpc script written."

# ── Copy imaging script ───────────────────────────────────────────────────────
log "Copying imaging.sh..."
cp "$SCRIPT_DIR/imaging.sh" "$WORK_DIR/rootfs/usr/local/bin/imaging.sh"
chmod +x "$WORK_DIR/rootfs/usr/local/bin/imaging.sh"
log "  imaging.sh installed."

# ── Deploy to Monolith ────────────────────────────────────────────────────────
log "Syncing netboot root to $MONOLITH_USER@$MONOLITH:$NETBOOT_PATH ..."
rsync -av --delete --progress \
    "$WORK_DIR/rootfs/" \
    "$MONOLITH_USER@$MONOLITH:$NETBOOT_PATH/"
log "Netboot root deployed."

# Replace TFTP cmdline.txt with our custom version
log "Deploying cmdline.txt to TFTP root..."
rsync -av "$SCRIPT_DIR/cmdline.txt" "$MONOLITH_USER@$MONOLITH:$TFTP_PATH/cmdline.txt"
log "cmdline.txt deployed."

log ""
log "=== Setup complete ==="
log "Nodes will image themselves automatically on next netboot."
log "Monitor progress via the network KVM."
