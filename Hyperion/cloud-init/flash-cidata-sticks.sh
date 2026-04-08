#!/usr/bin/env bash
# flash-cidata-sticks.sh
# Decrypts user-data.template.yaml and flashes cidata USB sticks for all
# Hyperion nodes. Run from the Hyperion/ directory.
#
# Usage: ./cloud-init/flash-cidata-sticks.sh [node-name]
#   No argument  → flash all 10 nodes in order
#   Node name    → flash a single node (e.g. hyperion-alpha)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
USER_DATA_ENC="$SCRIPT_DIR/user-data.template.yaml"
NODES=(alpha beta gamma delta epsilon zeta eta theta iota kappa)
MOUNT_POINT="/tmp/cidata-flash"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v sops   >/dev/null || die "sops not found. Install it first."
command -v mkfs.fat >/dev/null || die "mkfs.fat not found. Run: sudo apt-get install dosfstools"
[ -f "$AGE_KEY_FILE" ] || die "Age key not found at $AGE_KEY_FILE"
[ -f "$USER_DATA_ENC" ] || die "user-data.template.yaml not found at $USER_DATA_ENC"

# ── Determine which nodes to flash ───────────────────────────────────────────
if [ $# -eq 1 ]; then
    # Single node mode
    NODE_ARG="${1#hyperion-}"  # strip prefix if provided
    [[ " ${NODES[*]} " == *" $NODE_ARG "* ]] || die "Unknown node: $1. Valid names: ${NODES[*]}"
    TARGET_NODES=("$NODE_ARG")
else
    TARGET_NODES=("${NODES[@]}")
fi

# ── Decrypt user-data once ────────────────────────────────────────────────────
log "Decrypting user-data.template.yaml..."
DECRYPTED_USER_DATA="$(SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt "$USER_DATA_ENC")"
log "  Decryption successful."

# ── Flash one stick ───────────────────────────────────────────────────────────
flash_node() {
    local greek="$1"
    local hostname="hyperion-$greek"
    local meta_data="$SCRIPT_DIR/nodes/$hostname/meta-data"

    [ -f "$meta_data" ] || die "meta-data not found: $meta_data"

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Node: $hostname${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Insert the USB stick for $hostname and press ENTER."
    echo "  (Any existing data on the stick will be erased.)"
    echo ""

    read -r -p "  Ready? [ENTER to continue, q to quit] " response
    [ "$response" = "q" ] && { log "Aborted."; exit 0; }

    # Find USB disk(s) currently connected
    log "Detecting USB device..."
    local usb_devices
    usb_devices="$(lsblk -o NAME,TRAN,TYPE --json | jq -r '
        .blockdevices[] |
        select(.tran=="usb" and .type=="disk") |
        .name')"

    local device=""
    local count
    count="$(echo "$usb_devices" | grep -c . || true)"

    if [ "$count" -eq 1 ]; then
        device="$(echo "$usb_devices" | head -1)"
        log "  Detected: /dev/$device"
    elif [ "$count" -gt 1 ]; then
        warn "Multiple USB disks detected:"
        echo "$usb_devices" | while read -r d; do
            echo "    /dev/$d  $(lsblk -o SIZE -dn "/dev/$d")"
        done
        read -r -p "  Enter device name to use (e.g. sdb): " device
        [ -z "$device" ] && die "No device specified."
    else
        warn "No USB disk detected. Make sure the stick is inserted."
        lsblk -o NAME,TRAN,TYPE,SIZE
        read -r -p "  Enter device name manually (e.g. sdb): " device
        [ -z "$device" ] && die "No device specified."
    fi

    device="/dev/$device"
    log "  Detected: $device"

    # Confirm before erasing
    echo ""
    warn "About to FORMAT $device as FAT32 (label: cidata). ALL DATA WILL BE LOST."
    read -r -p "  Type 'yes' to confirm: " confirm
    [ "$confirm" = "yes" ] || { warn "Skipped $hostname."; return; }

    # Unmount if currently mounted
    if mount | grep -q "^$device"; then
        log "Unmounting $device..."
        sudo umount "${device}"* 2>/dev/null || true
    fi

    # Format as FAT32 with label cidata
    log "Formatting $device as FAT32 (label: cidata)..."
    sudo mkfs.fat -F 32 -I -n cidata "$device"

    # Mount and write files
    mkdir -p "$MOUNT_POINT"
    sudo mount "$device" "$MOUNT_POINT"

    log "Writing meta-data..."
    sudo cp "$meta_data" "$MOUNT_POINT/meta-data"

    log "Writing user-data..."
    echo "$DECRYPTED_USER_DATA" | sudo tee "$MOUNT_POINT/user-data" >/dev/null

    log "Verifying files on stick:"
    ls -lh "$MOUNT_POINT/"

    # Sync and unmount
    sync
    sudo umount "$MOUNT_POINT"
    log "  ${GREEN}$hostname done.${NC} Remove the USB stick and label it."
    echo ""
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
log "=== Hyperion cidata USB Flash Tool ==="
log "Nodes to flash: ${TARGET_NODES[*]}"
echo ""

for greek in "${TARGET_NODES[@]}"; do
    flash_node "$greek"
done

rmdir "$MOUNT_POINT" 2>/dev/null || true

echo ""
log "=== All done. ==="
log "Each stick is labelled 'cidata' and contains meta-data + user-data."
log "Insert the correctly labelled stick into each Pi before powering on."
