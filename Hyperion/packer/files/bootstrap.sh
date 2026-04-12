#!/bin/bash
# bootstrap.sh
# Hyperion node Bootstrap script.
#
# Runs on every boot from the Bootstrap SD card via hyperion-bootstrap.service.
#
# Boot flow (USB-authoritative):
#   0. Ensure EEPROM BOOT_ORDER=0xf641 (SD → USB → NVMe → loop) — staged if wrong, takes effect on reboot
#   1. Update identity USB cache from Monolith if a newer Node IMG is available
#      (network is optional — gracefully skipped if Monolith is unreachable)
#   2. Flash NVMe from USB cache if NVMe is behind USB version
#   3. Repartition NVMe (resize p2 → 32 GiB, create p3, mkfs)
#   4. Reboot into NVMe
#
# If NVMe already matches the USB version, reboots immediately.
# After MAX_BOOT_ATTEMPTS consecutive failures, drops to a shell for diagnosis.
#
# Feedback channels (both active during bootstrap):
#   LED blink codes (ACT green LED):
#     slow blink  (1s on / 1s off)    — working / general progress
#     fast blink  (0.25s/0.25s)       — downloading image
#     rapid blink (0.1s/0.1s)         — flashing NVMe (do not interrupt)
#     solid on                         — complete, rebooting
#     SOS  (···---···)                — fatal error, dropped to shell
#   HTTP status endpoint (port 8080):
#     GET http://<node-ip>:8080/       — full JSON status
#     JSON fields: hostname, step, total_steps, phase, message,
#                  status (working|downloading|flashing|done|error),
#                  attempt, started_at, updated_at, error
set -euo pipefail

MONOLITH_BASE="http://192.168.10.247:50011"
MANIFEST_URL="$MONOLITH_BASE/node/manifest.json"
IMAGE_BASE_URL="$MONOLITH_BASE/node"
NVME="/dev/nvme0n1"
ROOT_SIZE="32GiB"
NET_TIMEOUT=10      # seconds for manifest fetch
USB_WAIT=30         # seconds to wait for HYPERION-ID USB enumeration
MAX_BOOT_ATTEMPTS=3 # drop to shell after this many consecutive failures

STATUS_FILE="/tmp/bootstrap-status.json"
STATUS_PORT=8080
LED_PATH="/sys/class/leds/ACT"
TOTAL_STEPS=8

log()  { echo "[$(date '+%T')] [bootstrap] $*" | tee -a "${LOG_FILE:-/dev/null}"; }
warn() { echo "[$(date '+%T')] [bootstrap] WARN: $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
die()  {
    local msg="$*"
    echo "[$(date '+%T')] [bootstrap] FATAL: $msg" | tee -a "${LOG_FILE:-/dev/null}" >&2
    set_status "error" "${CURRENT_STEP:-0}" "$msg" "error" "$msg"
    _led_sos
    exit 1
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ── LED control ───────────────────────────────────────────────────────────────
LED_PID=""

_led_write() {
    # Write to a LED sysfs attribute if the LED exists.
    [ -d "$LED_PATH" ] || return 0
    echo "$2" > "$LED_PATH/$1" 2>/dev/null || true
}

_led_init() {
    _led_write trigger none
    _led_write brightness 0
}

_led_off() {
    if [ -n "$LED_PID" ]; then
        kill "$LED_PID" 2>/dev/null || true
        LED_PID=""
    fi
    _led_write brightness 0
}

_led_on() {
    _led_off
    _led_write brightness 1
}

# _led_blink <on_ms> <off_ms>  — runs a blink loop in the background
_led_blink() {
    local on_ms="$1" off_ms="$2"
    _led_off
    (
        while true; do
            _led_write brightness 1
            sleep "$(echo "scale=3; $on_ms/1000" | bc)"
            _led_write brightness 0
            sleep "$(echo "scale=3; $off_ms/1000" | bc)"
        done
    ) &
    LED_PID=$!
}

# Slow blink: 1s on / 1s off — general working state
_led_working()     { _led_blink 1000 1000; }
# Fast blink: 250ms/250ms — downloading
_led_downloading() { _led_blink 250 250; }
# Rapid blink: 100ms/100ms — flashing NVMe (do not interrupt!)
_led_flashing()    { _led_blink 100 100; }

# SOS in Morse: ···---···  (3 short, 3 long, 3 short)
_led_sos() {
    _led_off
    [ -d "$LED_PATH" ] || return 0
    local short=200 long=600 gap=200 letter_gap=600
    _blink_pulse() {
        local dur="$1"
        _led_write brightness 1; sleep "$(echo "scale=3; $dur/1000" | bc)"
        _led_write brightness 0; sleep "$(echo "scale=3; $gap/1000" | bc)"
    }
    while true; do
        # S: 3 short
        _blink_pulse $short; _blink_pulse $short; _blink_pulse $short
        sleep "$(echo "scale=3; $letter_gap/1000" | bc)"
        # O: 3 long
        _blink_pulse $long; _blink_pulse $long; _blink_pulse $long
        sleep "$(echo "scale=3; $letter_gap/1000" | bc)"
        # S: 3 short
        _blink_pulse $short; _blink_pulse $short; _blink_pulse $short
        sleep 2
    done
}

# ── HTTP status server ────────────────────────────────────────────────────────
STATUS_SERVER_PID=""
CURRENT_STEP=0
BOOTSTRAP_START="$(date -Iseconds)"
# Updated to the node's real identity once the USB stick is read (step 1).
NODE_HOSTNAME="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]' || echo "unknown")"

# Write status JSON. Args: phase step message status [error]
set_status() {
    local phase="$1" step="$2" message="$3" status="$4" error="${5:-null}"
    CURRENT_STEP="$step"
    local error_field
    if [ "$error" = "null" ]; then
        error_field="null"
    else
        error_field="\"$(echo "$error" | sed 's/"/\\"/g')\""
    fi
    cat > "$STATUS_FILE" <<EOF
{
  "hostname":    "$NODE_HOSTNAME",
  "step":        $step,
  "total_steps": $TOTAL_STEPS,
  "phase":       "$phase",
  "message":     "$(echo "$message" | sed 's/"/\\"/g')",
  "status":      "$status",
  "attempt":     ${ATTEMPT:-1},
  "started_at":  "$BOOTSTRAP_START",
  "updated_at":  "$(date -Iseconds)",
  "error":       $error_field
}
EOF
}

_start_status_server() {
    # Serve STATUS_FILE as a JSON response on STATUS_PORT using Python3.
    # Python3 is always present on Pi OS — no extra packages needed.
    cat > /tmp/bootstrap-httpd.py <<'PYEOF'
import http.server, sys, json

port = int(sys.argv[1])
status_file = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass  # suppress access log noise
    def do_GET(self):
        try:
            with open(status_file) as f:
                data = f.read()
        except Exception as e:
            data = json.dumps({"error": str(e)})
        encoded = data.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

http.server.HTTPServer(("", port), Handler).serve_forever()
PYEOF
    python3 /tmp/bootstrap-httpd.py "$STATUS_PORT" "$STATUS_FILE" &
    STATUS_SERVER_PID=$!
    log "Status server running on port $STATUS_PORT (PID $STATUS_SERVER_PID)"
}

# ── Cleanup tracking ──────────────────────────────────────────────────────────
MOUNTS_TO_CLEAN=()
cleanup() {
    sync
    # Stop background processes
    if [ -n "$LED_PID" ]; then
        kill "$LED_PID" 2>/dev/null || true
    fi
    if [ -n "$STATUS_SERVER_PID" ]; then
        kill "$STATUS_SERVER_PID" 2>/dev/null || true
    fi
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

# ── Initialise feedback channels ──────────────────────────────────────────────
_led_init
set_status "starting" 0 "Bootstrap starting (attempt $ATTEMPT)" "working"
_start_status_server
_led_working

# ── 0. Ensure correct EEPROM boot order ──────────────────────────────────────
CURRENT_STEP=0
set_status "eeprom_check" 0 "Checking EEPROM boot order" "working"
TARGET_BOOT_ORDER="0xf641"
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
CURRENT_STEP=1
set_status "usb_wait" 1 "Waiting for HYPERION-ID USB (up to ${USB_WAIT}s)" "working"
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
NODE_HOSTNAME="$HOSTNAME"   # update status JSON hostname from bootstrap SD → identity USB
log "Bootstrap attempt : $ATTEMPT / $MAX_BOOT_ATTEMPTS"
log "Node identity     : $HOSTNAME"

USB_VER_RAW=$(cat "$CACHE_DIR/version" 2>/dev/null | tr -d '[:space:]' || echo 0)
is_int "$USB_VER_RAW" && USB_VER="$USB_VER_RAW" || USB_VER=0
log "USB cache version : $USB_VER"

# ── 2. Try network manifest (non-fatal on failure) ────────────────────────────
CURRENT_STEP=2
# Wait for a default route before attempting network — dhcpcd on Pi OS Trixie
# satisfies network-online.target before a lease is actually obtained, so we
# cannot rely solely on the systemd unit ordering.
NET_WAIT=60
set_status "network_wait" 2 "Waiting for network (up to ${NET_WAIT}s)" "working"
log "Waiting for default route (up to ${NET_WAIT}s)..."
NET_READY=false
for i in $(seq 1 "$NET_WAIT"); do
    if ip route show default 2>/dev/null | grep -q default; then
        NET_READY=true
        log "Network ready after ${i}s."
        break
    fi
    sleep 1
done
if [ "$NET_READY" = "false" ]; then
    warn "No default route after ${NET_WAIT}s — will use USB cache only."
fi

set_status "network_check" 2 "Checking Monolith for latest image version" "working"
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
    CURRENT_STEP=3
    set_status "downloading" 3 "Downloading $IMG_FILE (v$USB_VER → v$NET_VER)" "downloading"
    _led_downloading
    log "Downloading $IMG_FILE ($USB_VER → $NET_VER)..."
    DOWNLOAD_PATH="$CACHE_DIR/$IMG_FILE"

    curl -f --progress-bar "$IMAGE_BASE_URL/$IMG_FILE" -o "$DOWNLOAD_PATH.tmp" \
        || die "Download of $IMG_FILE failed."

    if [ -n "$IMG_SHA256" ] && [ "$IMG_SHA256" != "unknown" ] && [ "$IMG_SHA256" != "null" ]; then
        set_status "verifying" 3 "Verifying SHA256 of downloaded image" "working"
        _led_working
        ACTUAL_SHA=$(sha256sum "$DOWNLOAD_PATH.tmp" | awk '{print $1}')
        [ "$ACTUAL_SHA" = "$IMG_SHA256" ] \
            || die "SHA256 mismatch — expected $IMG_SHA256, got $ACTUAL_SHA. Aborting."
        log "SHA256 verified."
    else
        warn "No valid SHA256 in manifest — skipping integrity verification."
    fi

    # Commit the new image, then clean up old ones
    mv "$DOWNLOAD_PATH.tmp" "$DOWNLOAD_PATH"
    find "$CACHE_DIR" -name '*.img' ! -name "$(basename "$DOWNLOAD_PATH")" \
        -delete 2>/dev/null || true

    # Write version atomically (exFAT: tmp+mv is safer than in-place write)
    echo "$NET_VER" > "$CACHE_DIR/version.tmp"
    sync
    mv "$CACHE_DIR/version.tmp" "$CACHE_DIR/version"
    sync

    USB_VER="$NET_VER"
    log "USB cache updated to version $USB_VER."
    _led_working
elif [ "$NETWORK_UP" = "true" ]; then
    log "USB cache is current (version $USB_VER)."
fi

# ── 4. Verify USB has an image to flash ───────────────────────────────────────
CURRENT_STEP=4
set_status "usb_verify" 4 "Verifying USB image cache" "working"
USB_IMG=""
for f in "$CACHE_DIR"/*.img; do
    [ -f "$f" ] && USB_IMG="$f" && break
done
[ -n "$USB_IMG" ] \
    || die "No image in USB cache and network was unreachable. Cannot flash NVMe."
log "USB image : $(basename "$USB_IMG")  (version $USB_VER)"

# ── 5. Compare USB version vs NVMe version ────────────────────────────────────
CURRENT_STEP=5
set_status "version_check" 5 "Comparing USB vs NVMe image versions" "working"
NVME_VER=0
if [ -b "${NVME}p1" ]; then
    TMPBOOT=$(mktemp -d)
    MOUNTS_TO_CLEAN+=("$TMPBOOT")
    if mount -o ro "${NVME}p1" "$TMPBOOT" 2>/dev/null; then
        NVME_VER_RAW=$(cat "$TMPBOOT/node-img.ver" 2>/dev/null | tr -d '[:space:]' || echo 0)
        is_int "$NVME_VER_RAW" && NVME_VER="$NVME_VER_RAW" || NVME_VER=0
        umount "$TMPBOOT"
    fi
    rm -rf "$TMPBOOT"
fi
log "NVMe version      : $NVME_VER"

if [ "$NVME_VER" -ge "$USB_VER" ]; then
    CURRENT_STEP=8
    set_status "done" 8 "NVMe is current (v$NVME_VER). Rebooting into NVMe." "done"
    _led_on
    log "NVMe is current. Clearing attempt counter. Rebooting into NVMe..."
    rm -f "$ATTEMPT_FILE"
    sleep 2
    systemctl reboot
fi

# ── 6. Flash NVMe from USB cache ──────────────────────────────────────────────
CURRENT_STEP=6
set_status "flashing" 6 "Flashing NVMe from USB cache (v$USB_VER) — do not interrupt" "flashing"
_led_flashing
log "Flashing NVMe from USB cache (version $USB_VER)..."
dd if="$USB_IMG" of="$NVME" bs=4M conv=fsync status=progress
sync
partprobe "$NVME"
udevadm settle --timeout=10

# Wipe the version stamp BEFORE repartition.
# If repartition fails mid-way, NVME_VER reads as 0 on next boot and re-flash
# is triggered — prevents booting into a partially-repartitioned NVMe.
TMPBOOT=$(mktemp -d)
MOUNTS_TO_CLEAN+=("$TMPBOOT")
mount "${NVME}p1" "$TMPBOOT"
rm -f "$TMPBOOT/node-img.ver"
sed -i 's| init=/usr/lib/raspi-config/init_resize\.sh||g' \
    "$TMPBOOT/cmdline.txt" 2>/dev/null || true
umount "$TMPBOOT"
rm -rf "$TMPBOOT"

# ── 7. Repartition NVMe ───────────────────────────────────────────────────────
CURRENT_STEP=7
set_status "repartitioning" 7 "Resizing root partition and creating node-storage" "working"
_led_working
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
MOUNTS_TO_CLEAN+=("$TMPROOT")
mount "${NVME}p2" "$TMPROOT"
mkdir -p "$TMPROOT/mnt/node-storage"
umount "$TMPROOT"
rm -rf "$TMPROOT"

# ── 8. Success — clear attempt counter and reboot ─────────────────────────────
CURRENT_STEP=8
set_status "done" 8 "Flash complete. Rebooting into NVMe." "done"
_led_on
log "Flash complete. Clearing attempt counter."
rm -f "$ATTEMPT_FILE"
log "Rebooting into NVMe..."
sleep 2
systemctl reboot
