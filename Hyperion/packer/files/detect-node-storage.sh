#!/bin/bash
# detect-node-storage.sh
# Detects the preferred node-storage device at boot and injects a systemd
# drop-in to override the default mnt-node-storage.mount unit if a USB
# storage device is found.
#
# Priority:
#   1. Block device labeled "node-storage-usb"
#   2. Any USB block device larger than 200 GB
#   3. NVMe p3 (label: node-storage) — default, no override needed
set -euo pipefail
shopt -u failglob 2>/dev/null || true

DROPIN=/run/systemd/system/mnt-node-storage.mount.d/override.conf

resolve_partition() {
    # Given a raw block device, return its first partition device path.
    # Falls back to the raw device if no partition is found.
    local dev="$1"
    local part
    part=$(lsblk -ln -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"{print "/dev/"$1; exit}')
    echo "${part:-$dev}"
}

# 1. Label-based detection
if RAW_DEV=$(blkid -L node-storage-usb 2>/dev/null); then
    USB_DEV=$(resolve_partition "$RAW_DEV")
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Mount]\nWhat=%s\n' "$USB_DEV" > "$DROPIN"
    systemctl daemon-reload
    echo "detect-node-storage: using labeled USB storage at $USB_DEV"
    exit 0
fi

# 2. Size-based fallback: any /dev/sd? block device larger than 200 GB
#    (On Pi 5, all sd? devices are USB-attached — no native SATA controller)
for dev in /dev/sd?; do
    [ -b "$dev" ] || continue
    size_bytes=$(lsblk -bdn -o SIZE "$dev" 2>/dev/null) || continue
    [ "$size_bytes" -gt 214748364800 ] || continue
    PART=$(resolve_partition "$dev")
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Mount]\nWhat=%s\n' "$PART" > "$DROPIN"
    systemctl daemon-reload
    echo "detect-node-storage: using USB HDD partition at $PART ($(( size_bytes / 1073741824 )) GB)"
    exit 0
done

echo "detect-node-storage: no USB storage found — using NVMe p3 (LABEL=node-storage)"
