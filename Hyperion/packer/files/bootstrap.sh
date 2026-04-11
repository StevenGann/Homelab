#!/bin/bash
# bootstrap.sh
# Hyperion node Bootstrap script.
#
# Runs on every boot from the Bootstrap SD card via hyperion-bootstrap.service.
#
# Boot flow (USB-authoritative):
#   0. Ensure EEPROM BOOT_ORDER=0xf61 (SD → NVMe → loop) — staged if wrong, takes effect on reboot
#   1. Update identity USB cache from Monolith if a newer Node IMG is available
#      (network is optional — gracefully skipped if Monolith is unreachable)
#   2. Flash NVMe from USB cache if NVMe is behind USB version
#   3. Repartition NVMe (resize p2 → 32 GiB, create p3, mkfs)
#   4. Reboot into NVMe
#
# If NVMe already matches the USB version, reboots immediately.
# After MAX_BOOT_ATTEMPTS consecutive failures, drops to a shell for diagnosis.
set -euo pipefail

MONOLITH_BASE="http://192.168.10.247:50011"
MANIFEST_URL="$MONOLITH_BASE/node/manifest.json"
IMAGE_BASE_URL="$MONOLITH_BASE/node"
NVME="/dev/nvme0n1"
ROOT_SIZE="32GiB"
NET_TIMEOUT=10      # seconds for manifest fetch
USB_WAIT=30         # seconds to wait for HYPERION-ID USB enumeration
MAX_BOOT_ATTEMPTS=3 # drop to shell after this many consecutive failures

log()  { echo "[$(date '+%T')] [bootstrap] $*" | tee -a "${LOG_FILE:-/dev/null}"; }
warn() { echo "[$(date '+%T')] [bootstrap] WARN: $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
die()  { echo "[$(date '+%T')] [bootstrap] FATAL: $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; exit 1; }

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ── Cleanup tracking ──────────────────────────────────────────────────────────
MOUNTS_TO_CLEAN=()
cleanup() {
    sync
    for m in "${MOUNTS_TO_CLEAN[@]:-}"; do
        umount "$m" 2>/dev/null || true
        rm -rf "$m"
    done
}
trap cleanup EXIT

# ── Boot attempt counter ──────────────────────────────────────────────────────
# Written to the Bootstrap SD card (/boot) so it survives reboots.
ATTEMPT_FILE=/boot/bootstrap-attempts
ATTEMPT=1
if [ -f "$ATTEMPT_FILE" ]; then
    ATTEMPT=$(( $(cat "$ATTEMPT_FILE") + 1 ))
fi
echo "$ATTEMPT" > "$ATTEMPT_FILE"

if [ "$ATTEMPT" -gt "$MAX_BOOT_ATTEMPTS" ]; then
    echo "Bootstrap has failed $MAX_BOOT_ATTEMPTS times consecutively." >&2
    echo "Dropping to shell. Fix the issue, then run:" >&2
    echo "  rm $ATTEMPT_FILE && reboot" >&2
    rm -f "$ATTEMPT_FILE"
    exec /bin/bash
fi

# ── 0. Ensure correct EEPROM boot order ──────────────────────────────────────
TARGET_BOOT_ORDER="0xf61"
if command -v rpi-eeprom-config >/dev/null 2>&1; then
    CURRENT_ORDER=$(rpi-eeprom-config 2>/dev/null | grep '^BOOT_ORDER=' | cut -d= -f2 || true)
    if [ "${CURRENT_ORDER:-}" != "$TARGET_BOOT_ORDER" ]; then
        log "EEPROM BOOT_ORDER is '${CURRENT_ORDER:-unset}' — updating to $TARGET_BOOT_ORDER..."
        CURRENT_CONFIG=$(rpi-eeprom-config 2>/dev/null || echo "")
        if echo "$CURRENT_CONFIG" | grep -q '^BOOT_ORDER='; then
            NEW_CONFIG=$(echo "$CURRENT_CONFIG" | sed "s/^BOOT_ORDER=.*/BOOT_ORDER=$TARGET_BOOT_ORDER/")
        else
            NEW_CONFIG="${CURRENT_CONFIG}"$'\n'"BOOT_ORDER=$TARGET_BOOT_ORDER"
        fi
        EEPROM_TMP=$(mktemp)
        echo "$NEW_CONFIG" > "$EEPROM_TMP"
        rpi-eeprom-config --apply "$EEPROM_TMP" 2>/dev/null \
            && log "EEPROM update staged — takes effect on next reboot." \
            || warn "EEPROM update failed — boot order unchanged. Run configure-eeprom.sh manually."
        rm -f "$EEPROM_TMP"
    else
        log "EEPROM BOOT_ORDER already $TARGET_BOOT_ORDER."
    fi
else
    warn "rpi-eeprom-config not found — skipping EEPROM check."
fi

# ── 1. Find identity USB ──────────────────────────────────────────────────────
log "Waiting for HYPERION-ID USB (up to ${USB_WAIT}s)..."
ID_DEV=""
for i in $(seq 1 "$USB_WAIT"); do
    ID_DEV=$(blkid -L HYPERION-ID 2>/dev/null) && break
    sleep 1
done
[ -n "${ID_DEV:-}" ] || die "No HYPERION-ID USB found after ${USB_WAIT}s."

ID_MNT=$(mktemp -d)
MOUNTS_TO_CLEAN+=("$ID_MNT")
mount "$ID_DEV" "$ID_MNT"

CACHE_DIR="$ID_MNT/node-image"
mkdir -p "$CACHE_DIR"
LOG_FILE="$CACHE_DIR/bootstrap.log"

HOSTNAME=$(tr -d '[:space:]' < "$ID_MNT/hostname" 2>/dev/null || echo "unknown")
log "Bootstrap attempt : $ATTEMPT / $MAX_BOOT_ATTEMPTS"
log "Node identity     : $HOSTNAME"

USB_VER_RAW=$(cat "$CACHE_DIR/version" 2>/dev/null | tr -d '[:space:]' || echo 0)
is_int "$USB_VER_RAW" && USB_VER="$USB_VER_RAW" || USB_VER=0
log "USB cache version : $USB_VER"

# ── 2. Try network manifest (non-fatal on failure) ────────────────────────────
NET_VER=0
IMG_FILE=""
IMG_SHA256=""
NETWORK_UP=false

if MANIFEST=$(curl -sf --connect-timeout "$NET_TIMEOUT" --max-time "$NET_TIMEOUT" \
        "$MANIFEST_URL" 2>/dev/null); then
    NET_VER_RAW=$(echo "$MANIFEST" | jq -r '.current_version' 2>/dev/null | tr -d '[:space:]' || echo 0)
    is_int "$NET_VER_RAW" && NET_VER="$NET_VER_RAW" || NET_VER=0
    IMG_FILE=$(echo "$MANIFEST"   | jq -r '.image_file'   2>/dev/null || echo "")
    IMG_SHA256=$(echo "$MANIFEST" | jq -r '.image_sha256' 2>/dev/null || echo "")
    NETWORK_UP=true
    log "Network version   : $NET_VER"
else
    warn "Monolith unreachable — will use USB cache only."
fi

# ── 3. Update USB cache if network has a newer version ────────────────────────
if [ "$NETWORK_UP" = "true" ] && [ -n "$IMG_FILE" ] && [ "$NET_VER" -gt "$USB_VER" ]; then
    log "Downloading $IMG_FILE ($USB_VER → $NET_VER)..."
    DOWNLOAD_PATH="$CACHE_DIR/$IMG_FILE"

    curl -f --progress-bar "$IMAGE_BASE_URL/$IMG_FILE" -o "$DOWNLOAD_PATH.tmp" \
        || die "Download of $IMG_FILE failed."

    ACTUAL_SHA=$(sha256sum "$DOWNLOAD_PATH.tmp" | awk '{print $1}')
    [ "$ACTUAL_SHA" = "$IMG_SHA256" ] \
        || die "SHA256 mismatch — expected $IMG_SHA256, got $ACTUAL_SHA. Aborting."

    # Commit the new image, then clean up old ones
    mv "$DOWNLOAD_PATH.tmp" "$DOWNLOAD_PATH"
    find "$CACHE_DIR" -name '*.img.zst' ! -name "$(basename "$DOWNLOAD_PATH")" \
        -delete 2>/dev/null || true

    # Write version atomically (FAT32: tmp+mv is safer than in-place write)
    echo "$NET_VER" > "$CACHE_DIR/version.tmp"
    sync
    mv "$CACHE_DIR/version.tmp" "$CACHE_DIR/version"
    sync

    USB_VER="$NET_VER"
    log "USB cache updated to version $USB_VER."
elif [ "$NETWORK_UP" = "true" ]; then
    log "USB cache is current (version $USB_VER)."
fi

# ── 4. Verify USB has an image to flash ───────────────────────────────────────
USB_IMG=""
for f in "$CACHE_DIR"/*.img.zst; do
    [ -f "$f" ] && USB_IMG="$f" && break
done
[ -n "$USB_IMG" ] \
    || die "No image in USB cache and network was unreachable. Cannot flash NVMe."
log "USB image : $(basename "$USB_IMG")  (version $USB_VER)"

# ── 5. Compare USB version vs NVMe version ────────────────────────────────────
NVME_VER=0
if [ -b "${NVME}p1" ]; then
    TMPBOOT=$(mktemp -d)
    if mount -o ro "${NVME}p1" "$TMPBOOT" 2>/dev/null; then
        NVME_VER_RAW=$(cat "$TMPBOOT/node-img.ver" 2>/dev/null | tr -d '[:space:]' || echo 0)
        is_int "$NVME_VER_RAW" && NVME_VER="$NVME_VER_RAW" || NVME_VER=0
        umount "$TMPBOOT"
    fi
    rm -rf "$TMPBOOT"
fi
log "NVMe version      : $NVME_VER"

if [ "$NVME_VER" -ge "$USB_VER" ]; then
    log "NVMe is current. Clearing attempt counter. Rebooting into NVMe..."
    rm -f "$ATTEMPT_FILE"
    sleep 2
    systemctl reboot
fi

# ── 6. Flash NVMe from USB cache ──────────────────────────────────────────────
log "Flashing NVMe from USB cache (version $USB_VER)..."
zstd -dc "$USB_IMG" | dd of="$NVME" bs=4M conv=fsync status=progress
sync
partprobe "$NVME"
udevadm settle --timeout=10

# Wipe the version stamp BEFORE repartition.
# If repartition fails mid-way, NVME_VER reads as 0 on next boot and re-flash
# is triggered — prevents booting into a partially-repartitioned NVMe.
TMPBOOT=$(mktemp -d)
mount "${NVME}p1" "$TMPBOOT"
rm -f "$TMPBOOT/node-img.ver"
sed -i 's| init=/usr/lib/raspi-config/init_resize\.sh||g' \
    "$TMPBOOT/cmdline.txt" 2>/dev/null || true
umount "$TMPBOOT"
rm -rf "$TMPBOOT"

# ── 7. Repartition NVMe ───────────────────────────────────────────────────────
log "Resizing root partition (p2) to $ROOT_SIZE..."
parted -s "$NVME" resizepart 2 "$ROOT_SIZE"
partprobe "$NVME"
udevadm settle --timeout=10
e2fsck -f -p "${NVME}p2"
resize2fs "${NVME}p2"

log "Creating node-storage partition (p3)..."
parted -s "$NVME" mkpart primary ext4 "$ROOT_SIZE" 100%
partprobe "$NVME"
udevadm settle --timeout=10
mkfs.ext4 -L node-storage "${NVME}p3"

# Create mount point on NVMe root.
# No fstab entry — the systemd mnt-node-storage.mount unit (baked into the
# Node IMG) is the sole mount mechanism. Writing fstab here would create a
# duplicate unit and an ordering conflict.
TMPROOT=$(mktemp -d)
mount "${NVME}p2" "$TMPROOT"
mkdir -p "$TMPROOT/mnt/node-storage"
umount "$TMPROOT"
rm -rf "$TMPROOT"

# ── 8. Success — clear attempt counter and reboot ─────────────────────────────
log "Flash complete. Clearing attempt counter."
rm -f "$ATTEMPT_FILE"
log "Rebooting into NVMe..."
sleep 2
systemctl reboot
