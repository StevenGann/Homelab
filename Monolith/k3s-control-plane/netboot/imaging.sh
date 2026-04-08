#!/bin/sh
# Hyperion Node Imaging Script
# Runs as PID 2 from /init on the netboot NFS root.
# Flashes the Packer image to NVMe, partitions correctly, and reboots.
set -e

NVME="/dev/nvme0n1"
IMAGE_URL="http://192.168.10.247:50011/rpi-base.img"
ROOT_SIZE="32GiB"

log() {
    echo "[$(date '+%T')] [IMAGER] $*"
}

banner() {
    echo ""
    echo "============================================="
    echo "  $*"
    echo "============================================="
    echo ""
}

banner "Hyperion Node Imaging Script"
log "Target device : $NVME"
log "Image source  : $IMAGE_URL"
log "Root size     : $ROOT_SIZE"
log "Node-storage  : remainder (~220GiB)"

# ── Wait for network ──────────────────────────────────────────────────────────
log "Waiting for network connectivity to Monolith (192.168.10.247)..."
until ping -c 1 -W 2 192.168.10.247 >/dev/null 2>&1; do
    log "  ...no response, retrying in 3s"
    sleep 3
done
log "Network ready."

# ── Download and flash image ──────────────────────────────────────────────────
banner "Step 1/5: Flashing image to $NVME"
log "Streaming image from nginx — this will take several minutes."
curl -f --progress-bar "$IMAGE_URL" | dd of="$NVME" bs=4M conv=fsync status=progress
sync
log "Image flash complete. Syncing..."
partprobe "$NVME"
sleep 3
log "Partition table re-read."

# ── Disable root auto-expansion ───────────────────────────────────────────────
banner "Step 2/5: Disabling root partition auto-expansion"
mkdir -p /tmp/boot
mount "${NVME}p1" /tmp/boot
log "Boot partition mounted at /tmp/boot."
log "Current cmdline.txt:"
cat /tmp/boot/cmdline.txt
# Remove init_resize.sh invocation if present
sed -i 's| init=/usr/lib/raspi-config/init_resize\.sh||g' /tmp/boot/cmdline.txt
sed -i 's| quiet||g' /tmp/boot/cmdline.txt   # Enable verbose boot output
log "Updated cmdline.txt:"
cat /tmp/boot/cmdline.txt
umount /tmp/boot
log "Auto-expansion disabled."

# ── Resize root partition to 32GiB ───────────────────────────────────────────
banner "Step 3/5: Resizing root partition (p2) to $ROOT_SIZE"
parted -s "$NVME" resizepart 2 "$ROOT_SIZE"
partprobe "$NVME"
sleep 2
log "Running filesystem check on ${NVME}p2..."
e2fsck -f -p "${NVME}p2"
log "Resizing filesystem to fill p2..."
resize2fs "${NVME}p2"
log "Root partition resized successfully."

# ── Create node-storage partition ────────────────────────────────────────────
banner "Step 4/5: Creating node-storage partition (p3)"
parted -s "$NVME" mkpart primary ext4 "$ROOT_SIZE" 100%
partprobe "$NVME"
sleep 2
log "Formatting ${NVME}p3 as ext4 (label: node-storage)..."
mkfs.ext4 -L node-storage "${NVME}p3"
log "Storage partition created."

# ── Update fstab on root partition ───────────────────────────────────────────
banner "Step 5/5: Updating /etc/fstab"
mkdir -p /tmp/root
mount "${NVME}p2" /tmp/root
P3_PARTUUID=$(blkid -s PARTUUID -o value "${NVME}p3")
log "  ${NVME}p3 PARTUUID: $P3_PARTUUID"
mkdir -p /tmp/root/mnt/node-storage
echo "PARTUUID=$P3_PARTUUID  /mnt/node-storage  ext4  defaults,nofail  0  2" >> /tmp/root/etc/fstab
log "  fstab updated:"
grep node-storage /tmp/root/etc/fstab
umount /tmp/root
log "Root partition unmounted."

# ── Done ─────────────────────────────────────────────────────────────────────
banner "Imaging complete — rebooting in 5 seconds"
log "On next boot the node will start from its NVMe SSD."
log "cloud-init will run and the node will join the k3s cluster."
sleep 5
sync
reboot -f
