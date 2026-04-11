#!/usr/bin/env bash
# flash-identity-usb.sh
# Formats a USB stick as FAT32 (label HYPERION-ID) and writes a node hostname file.
# Run this once per node before first bootstrap, or whenever a USB stick is replaced.
#
# Usage:
#   ./flash-identity-usb.sh <device> <hostname>
#   ./flash-identity-usb.sh /dev/sdb hyperion-alpha
#
# The device will be completely erased.  Double-check the device path before running.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <device> <hostname>"
    echo ""
    echo "  device    Block device to format (e.g. /dev/sdb).  WILL BE ERASED."
    echo "  hostname  Hostname to write (e.g. hyperion-alpha)"
    echo ""
    echo "Examples:"
    echo "  $0 /dev/sdb hyperion-alpha"
    echo "  $0 /dev/sdc hyperion-beta"
    exit 1
}

# ── Arg validation ────────────────────────────────────────────────────────────
[ $# -eq 2 ] || usage

DEVICE="$1"
HOSTNAME="$2"

[[ "$DEVICE" == /dev/* ]] || die "Device must be a /dev/ path (got: $DEVICE)"
[ -b "$DEVICE" ]          || die "$DEVICE is not a block device"

# Refuse if device looks like a system disk (whole NVMe or first-listed disk)
[[ "$DEVICE" == *nvme* ]]       && die "Refusing to format NVMe device $DEVICE"
FIRST_DISK=$(lsblk -dno NAME | head -1)
[[ "$DEVICE" == "/dev/$FIRST_DISK" ]] && die "Refusing to format apparent system disk $DEVICE"

[[ "$HOSTNAME" =~ ^hyperion-[a-z]+$ ]] \
    || die "Hostname must match 'hyperion-<greek>' (got: $HOSTNAME)"

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
warn "This will ERASE all data on $DEVICE."
echo -e "  Device : ${CYAN}$DEVICE${NC}"
echo -e "  Label  : HYPERION-ID"
echo -e "  Host   : ${CYAN}$HOSTNAME${NC}"
echo ""
read -r -p "Type YES to confirm: " confirm
[ "$confirm" = "YES" ] || { echo "Aborted."; exit 0; }
echo ""

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v mkfs.exfat >/dev/null \
    || die "mkfs.exfat not found. Install exfatprogs: sudo apt-get install exfatprogs"

# ── Unmount any existing partitions ──────────────────────────────────────────
log "Unmounting any mounted partitions on $DEVICE..."
for part in "${DEVICE}"?*; do
    if mount | grep -q "^$part "; then
        umount "$part" 2>/dev/null && log "  Unmounted $part" || warn "Could not unmount $part — continuing"
    fi
done

# ── Partition table: single exFAT partition ───────────────────────────────────
# exFAT is used instead of FAT32 to avoid the 4GB per-file limit — the node
# image cache can hold a ~4GB uncompressed .img file.
log "Writing partition table..."
wipefs -a "$DEVICE" >/dev/null 2>&1 || true
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart HYPERION-ID 1MiB 100%
udevadm settle --timeout=10

PARTITION="${DEVICE}1"
# Some devices use p1 suffix (e.g. /dev/mmcblk0p1)
[ -b "$PARTITION" ] || PARTITION="${DEVICE}p1"
[ -b "$PARTITION" ] || die "Partition ${DEVICE}1 / ${DEVICE}p1 not found after partitioning"

log "Formatting $PARTITION as exFAT (label HYPERION-ID)..."
mkfs.exfat -L "HYPERION-ID" "$PARTITION"
udevadm settle --timeout=5

# ── Mount and write files ─────────────────────────────────────────────────────
MNT=$(mktemp -d)
trap "umount '$MNT' 2>/dev/null || true; rm -rf '$MNT'" EXIT

mount "$PARTITION" "$MNT"

log "Writing hostname file..."
printf '%s\n' "$HOSTNAME" > "$MNT/hostname"

log "Creating node-image cache directory..."
mkdir -p "$MNT/node-image"

sync
umount "$MNT"
rm -rf "$MNT"
trap - EXIT

echo ""
log "Done. Identity USB is ready for $HOSTNAME."
log "  Label    : HYPERION-ID"
log "  Hostname : $HOSTNAME"
log "  Image cache dir ready (empty — bootstrap will populate on first run)"
echo ""
warn "Insert this USB into the node's USB port before powering on with the Bootstrap SD card."
