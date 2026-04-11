# Hyperion Node Image Approach — Design Document

> **Status:** IMPLEMENTED — this design doc is now a historical reference.
> The implementation diverges from this document in several places (listed below).
> For current behavior, read the code and operational docs in `Hyperion/docs/runbooks/`.
>
> **Known divergences from implementation:**
> - §3: BOOT_ORDER is `0xf641` (SD→USB→NVMe→loop), not `0xf61` as written here
> - §5: Identity USB uses exFAT, not FAT32
> - §8: Bootstrap uses plain `dd` (ci-deploy decompresses on Monolith); USB cache stores `.img`, not `.img.zst`
> - §11: nginx listens on port `50011`, not `8080`
> - §12.1: `dtparam=pciex1_gen=3` (Gen 3), not `dtparam=pciex1`
> - §12.2: Bootstrap IMG `target_image_size` is 3 GiB, not 2 GiB
> - §13: CI publishes to GitHub Releases; ci-deploy polls GitHub API. The SSH+rsync approach described here was never implemented.
> - §13 secrets: Only `NODE_SSH_PUBLIC_KEY` is needed. `MONOLITH_SSH_KEY`, `MONOLITH_HOST_KEY`, `MONOLITH_HOST` do not exist.
>
> **Replaces:** TFTP netboot + initramfs approach (abandoned; Pi 5 compatibility issues).
> **Reviews completed:** linux-expert, sysadmin-expert, pi-expert, fact-checker.

---

## 1. Background and Motivation

Two netboot approaches were attempted for the Hyperion cluster:

1. **NFS root + kexec** — Failed. NFS is a kernel module in Pi OS Trixie; without an initramfs the kernel cannot load it before mounting root. kexec is also fundamentally broken on Pi 5: the RP1 southbridge is not re-initialized after kexec. (Upstream: raspberrypi/linux#6465)

2. **Self-contained Alpine initramfs over TFTP** — Failed. After TFTP downloads completed, nodes hung indefinitely. Suspected cause: `macb` Ethernet driver fails to load in the Alpine initramfs context.

**Decision:** Abandon netboot entirely. Use a two-image SD-card-based approach with no TFTP dependency.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub Actions (CI/CD)                                             │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  On push to main (Packer files changed) or manual dispatch:   │ │
│  │  1. packer build rpi-node.pkr.hcl  (ARM64 via QEMU)          │ │
│  │  2. zstd -19 → rpi-node-<EPOCH>.img.zst                      │ │
│  │  3. sha256sum → manifest.json                                 │ │
│  │  4. rsync → Monolith (via restricted deploy key)              │ │
│  │  Bootstrap IMG: separate job, triggered by bootstrap/* changes│ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
                         │ rsync (restricted SSH deploy key)
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Monolith (192.168.10.247)                                          │
│  nginx (port 50011) → /srv/images/node/                             │
│    manifest.json  |  rpi-node-<EPOCH>.img.zst  |  rpi-node-latest  │
└─────────────────────────────────────────────────────────────────────┘
                         │ HTTP (LAN only)
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Hyperion node (Pi 5)                                               │
│  ┌──────────────────┐   ┌───────────────────────────────────────┐  │
│  │  SD card          │   │  Identity USB  (label: HYPERION-ID)   │  │
│  │  Bootstrap IMG    │   │  ├── hostname       "hyperion-alpha"   │  │
│  │  (identical on    │   │  └── node-image/    IMG cache          │  │
│  │   all nodes)      │   │      ├── version    epoch int          │  │
│  └──────────────────┘   │      └── rpi-node-<V>.img.zst          │  │
│                          └───────────────────────────────────────┘  │
│  NVMe /dev/nvme0n1 (256 GB)                                         │
│    p1:  512 MB  FAT32  /boot/firmware  (Pi firmware + kernel)       │
│    p2:   32 GB  ext4   /                                            │
│    p3: ~220 GB  ext4   /mnt/node-storage                           │
│          └── USB HDD (label: node-storage-usb, >200 GB) overrides  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. EEPROM Boot Order

**`BOOT_ORDER=0xf61` — SD → NVMe → restart loop. Set once, never changed.**

Nibbles read right-to-left: 1 (SD) → 6 (NVMe) → f (restart).

When no SD card is inserted, Pi 5 skips the SD slot in ~2–3 seconds and boots NVMe. The Bootstrap SD is a universal escape hatch: insert → power-cycle → re-image.

**EEPROM is stored in SPI flash** — re-imaging NVMe does not affect BOOT_ORDER. (Fact-checker: CONFIRMED)

**Additional EEPROM settings to apply at deployment:**
- `BOOT_UART=1` — enables bootloader output on UART (GPIO 14/15, 115200 baud) for debugging. Disable after cluster is stable.
- `BOOT_ORDER=0xf61` — as above.

**Before first deployment: update EEPROM firmware on all nodes.**
```bash
sudo rpi-eeprom-update -a && sudo reboot
```
Nodes purchased in different batches may have different EEPROM firmware versions with different NVMe boot behavior. Standardize to the same version before proceeding.

> **`configure-eeprom.sh`** currently defaults to `0xf612` (Network→SD→NVMe). Update to `0xf61`. Network boot is no longer needed.

---

## 4. Image Catalogue

### 4.1 Node IMG (`rpi-node-<EPOCH>.img.zst`)

Pi OS Trixie arm64, built by Packer in CI, compressed zstd -19 (~4 GB raw → ~1.4–1.8 GB). Contains:

- User `owner` (created by Packer; `pi` user deleted)
- SSH authorized keys for `owner`
- Packages: `curl`, `jq`, `git`, `nfs-common`, `open-iscsi`, `zstd`
- k3s installed via official install script (units created, not enabled)
- cgroup params in `cmdline.txt`
- Root auto-expansion disabled
- `apply-identity.service` + `detect-node-storage.service` + `mnt-node-storage.mount`
- `/boot/firmware/node-img.ver` — Unix epoch integer
- `config.txt` entries for Pi 5 NVMe boot (see §4.3)
- cloud-init **purged** (`apt-get purge cloud-init; rm -rf /etc/cloud /var/lib/cloud`)

**Partition layout in image:** ~4 GB covering p1 (512 MB FAT32) + p2 (fills remainder). Bootstrap handles final NVMe partitioning.

### 4.2 Bootstrap IMG (`rpi-bootstrap.img`)

Minimal Pi OS Lite on SD card. Identical across all nodes. Contains `bootstrap.sh` + systemd unit. On every boot: updates USB cache from Monolith if newer, flashes NVMe from USB if NVMe is behind USB version, reboots.

### 4.3 Pi 5 `config.txt` entries (Node IMG)

Added to the `[pi5]` section:

```ini
[pi5]
kernel=kernel_2712.img
auto_initramfs=1
dtparam=pciex1_gen=3
dtparam=nvme
```

- `dtparam=pciex1` — explicitly enables PCIe lane (safe to include regardless of HAT type)
- `dtparam=nvme` — required by some EEPROM firmware versions for NVMe boot sequence; belt-and-suspenders
- `kernel_2712.img` — Pi 5 specific kernel (BCM2712)
- `auto_initramfs=1` — required for Pi OS Trixie which uses initramfs

> **PCIe Gen 3 enabled** (`dtparam=pciex1_gen=3`). Theoretical ~800 MB/s NVMe throughput vs ~400 MB/s at Gen 2.

---

## 5. Node Identity — The Identity USB Drive

Each node has a dedicated FAT32 USB stick, label `HYPERION-ID`:

```
HYPERION-ID/
├── hostname               # Plain text: "hyperion-alpha"
└── node-image/            # Written by Bootstrap
    ├── version            # Plain text epoch: "1744272000"
    └── rpi-node-1744272000.img.zst
```

**Detection:** `/dev/disk/by-label/HYPERION-ID` or `blkid -L HYPERION-ID`. Never `/dev/sdX`.

**Capacity:** Must hold the Node IMG (~1.5–2 GB). Minimum 4 GB; 16 GB recommended.

**Insert before power-on.** The Bootstrap script waits up to 30 seconds for the USB to enumerate, but the identity USB must be physically present before boot. USB HDDs can take 8–15 seconds to spin up; if both identity USB and a storage HDD are present, 30 seconds covers worst-case enumeration.

---

## 6. First-Boot Identity Application

```ini
# /etc/systemd/system/apply-identity.service
[Unit]
Description=Apply node identity from HYPERION-ID USB
ConditionPathExists=!/etc/hyperion-identity-applied
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/apply-identity.sh

[Install]
WantedBy=multi-user.target
```

```bash
#!/bin/bash
# /usr/local/bin/apply-identity.sh
set -euo pipefail

GUARD=/etc/hyperion-identity-applied
[ -f "$GUARD" ] && exit 0   # idempotent even if run manually

# Wait for USB enumeration (up to 15 s on NVMe boot — less contention than Bootstrap)
for i in $(seq 1 15); do
    ID_DEV=$(blkid -L HYPERION-ID 2>/dev/null) && break
    sleep 1
done

if [ -z "${ID_DEV:-}" ]; then
    echo "apply-identity: no HYPERION-ID USB found — hostname unchanged" >&2
    exit 0
fi

ID_MNT=$(mktemp -d)
trap "umount $ID_MNT 2>/dev/null || true; rm -rf $ID_MNT" EXIT
mount -o ro "$ID_DEV" "$ID_MNT"

HOSTNAME=$(tr -d '[:space:]' < "$ID_MNT/hostname")
[ -n "$HOSTNAME" ] || { echo "apply-identity: hostname file empty" >&2; exit 1; }

hostnamectl set-hostname "$HOSTNAME"
grep -q "$HOSTNAME" /etc/hosts || echo "127.0.1.1  $HOSTNAME" >> /etc/hosts

touch "$GUARD"
echo "apply-identity: hostname set to $HOSTNAME"
```

---

## 7. Node-Storage Mount

The systemd mount unit is the **sole mechanism** for mounting `/mnt/node-storage`. The Bootstrap script does not write an fstab entry for p3 — that would create a duplicate unit conflict with the systemd mount unit.

```ini
# /etc/systemd/system/mnt-node-storage.mount
[Unit]
Description=Node-local storage
After=detect-node-storage.service

[Mount]
What=LABEL=node-storage
Where=/mnt/node-storage
Type=ext4
Options=defaults,nofail

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/detect-node-storage.service
[Unit]
Description=Detect node-storage device (USB HDD or NVMe p3)
Before=mnt-node-storage.mount
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/detect-node-storage.sh

[Install]
WantedBy=multi-user.target
```

```bash
#!/bin/bash
# /usr/local/bin/detect-node-storage.sh
set -euo pipefail
shopt -u failglob 2>/dev/null || true

DROPIN=/run/systemd/system/mnt-node-storage.mount.d/override.conf

resolve_partition() {
    # Given a raw block device, return its first partition
    local dev="$1"
    lsblk -ln -o NAME,TYPE "$dev" | awk '$2=="part"{print "/dev/"$1; exit}'
}

# Label-based detection first
if RAW_DEV=$(blkid -L node-storage-usb 2>/dev/null); then
    USB_DEV=$(resolve_partition "$RAW_DEV" || echo "$RAW_DEV")
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Mount]\nWhat=%s\n' "$USB_DEV" > "$DROPIN"
    systemctl daemon-reload
    echo "detect-node-storage: using labeled USB storage at $USB_DEV"
    exit 0
fi

# Size-based fallback: any USB block device >200 GB
for dev in /dev/sd?; do
    [ -b "$dev" ] || continue
    size_bytes=$(lsblk -bdn -o SIZE "$dev" 2>/dev/null) || continue
    [ "$size_bytes" -gt 214748364800 ] || continue
    PART=$(resolve_partition "$dev" || echo "$dev")
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Mount]\nWhat=%s\n' "$PART" > "$DROPIN"
    systemctl daemon-reload
    echo "detect-node-storage: using USB HDD partition at $PART ($(( size_bytes / 1073741824 )) GB)"
    exit 0
done

echo "detect-node-storage: no USB storage — using NVMe p3 (LABEL=node-storage)"
```

---

## 8. Bootstrap Script

```bash
#!/bin/bash
# /usr/local/bin/bootstrap.sh
# Boot flow (USB-authoritative):
#   1. Update USB cache from network if available and newer
#   2. Flash NVMe from USB cache if NVMe is behind USB version
#   3. Reboot into NVMe
set -euo pipefail

MONOLITH_BASE="http://192.168.10.247:50011"
MANIFEST_URL="$MONOLITH_BASE/node/manifest.json"
IMAGE_BASE_URL="$MONOLITH_BASE/node"
NVME="/dev/nvme0n1"
ROOT_SIZE="32GiB"
NET_TIMEOUT=10
USB_WAIT=30        # seconds — covers slow USB HDDs spinning up
MAX_BOOT_ATTEMPTS=3

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

mount_tmp() {
    local dir
    dir=$(mktemp -d)
    MOUNTS_TO_CLEAN+=("$dir")
    mount "$@" "$dir"
    echo "$dir"
}

# ── Boot attempt counter (prevents infinite reboot loops) ─────────────────────
ATTEMPT_FILE=/boot/bootstrap-attempts   # on Bootstrap SD, persists across reboots
ATTEMPT=1
if [ -f "$ATTEMPT_FILE" ]; then
    ATTEMPT=$(( $(cat "$ATTEMPT_FILE") + 1 ))
fi
echo "$ATTEMPT" > "$ATTEMPT_FILE"

if [ "$ATTEMPT" -gt "$MAX_BOOT_ATTEMPTS" ]; then
    echo "Bootstrap has failed $MAX_BOOT_ATTEMPTS times. Dropping to shell." >&2
    echo "Fix the issue and run 'rm $ATTEMPT_FILE && reboot' to retry." >&2
    rm -f "$ATTEMPT_FILE"
    exec /bin/bash
fi
log "Bootstrap attempt $ATTEMPT / $MAX_BOOT_ATTEMPTS"

# ── 1. Find identity USB ──────────────────────────────────────────────────────
log "Waiting for identity USB (HYPERION-ID, up to ${USB_WAIT}s)..."
ID_DEV=""
for i in $(seq 1 "$USB_WAIT"); do
    ID_DEV=$(blkid -L HYPERION-ID 2>/dev/null) && break
    sleep 1
done
[ -n "${ID_DEV:-}" ] || die "No HYPERION-ID USB found after ${USB_WAIT}s."

ID_MNT=$(mktemp -d)
MOUNTS_TO_CLEAN+=("$ID_MNT")
mount "$ID_DEV" "$ID_MNT"
LOG_FILE="$ID_MNT/node-image/bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"

HOSTNAME=$(tr -d '[:space:]' < "$ID_MNT/hostname" 2>/dev/null || echo "unknown")
log "Node identity : $HOSTNAME"

CACHE_DIR="$ID_MNT/node-image"
mkdir -p "$CACHE_DIR"
USB_VER_RAW=$(cat "$CACHE_DIR/version" 2>/dev/null | tr -d '[:space:]' || echo 0)
is_int "$USB_VER_RAW" && USB_VER="$USB_VER_RAW" || USB_VER=0
log "USB cache version : $USB_VER"

# ── 2. Try network manifest (non-fatal) ───────────────────────────────────────
NET_VER=0
IMG_FILE=""
IMG_SHA256=""
NETWORK_UP=false

if MANIFEST=$(curl -sf --connect-timeout "$NET_TIMEOUT" --max-time "$NET_TIMEOUT" "$MANIFEST_URL" 2>/dev/null); then
    NET_VER_RAW=$(echo "$MANIFEST" | jq -r '.current_version' 2>/dev/null | tr -d '[:space:]' || echo 0)
    is_int "$NET_VER_RAW" && NET_VER="$NET_VER_RAW" || NET_VER=0
    IMG_FILE=$(echo "$MANIFEST"  | jq -r '.image_file'   2>/dev/null || echo "")
    IMG_SHA256=$(echo "$MANIFEST" | jq -r '.image_sha256' 2>/dev/null || echo "")
    NETWORK_UP=true
    log "Network version   : $NET_VER"
else
    warn "Monolith unreachable — will use USB cache only."
fi

# ── 3. Update USB cache if network is newer ───────────────────────────────────
if [ "$NETWORK_UP" = "true" ] && [ -n "$IMG_FILE" ] && [ "$NET_VER" -gt "$USB_VER" ]; then
    log "Downloading $IMG_FILE to USB cache ($USB_VER → $NET_VER)..."
    DOWNLOAD_PATH="$CACHE_DIR/$IMG_FILE"

    curl -f --progress-bar "$IMAGE_BASE_URL/$IMG_FILE" -o "$DOWNLOAD_PATH.tmp" \
        || die "Download failed."

    ACTUAL_SHA=$(sha256sum "$DOWNLOAD_PATH.tmp" | awk '{print $1}')
    [ "$ACTUAL_SHA" = "$IMG_SHA256" ] \
        || die "SHA256 mismatch — expected $IMG_SHA256, got $ACTUAL_SHA."

    # Commit new image, then clean up old ones
    mv "$DOWNLOAD_PATH.tmp" "$DOWNLOAD_PATH"
    find "$CACHE_DIR" -name '*.img.zst' ! -name "$(basename "$DOWNLOAD_PATH")" -delete 2>/dev/null || true

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

# ── 4. Verify USB has an image ────────────────────────────────────────────────
USB_IMG=""
for f in "$CACHE_DIR"/*.img.zst; do
    [ -f "$f" ] && USB_IMG="$f" && break
done
[ -n "$USB_IMG" ] || die "No image in USB cache and network was unreachable."
log "USB image : $(basename "$USB_IMG")  (version $USB_VER)"

# ── 5. Compare USB version vs NVMe version ────────────────────────────────────
NVME_VER=0
if [ -b "${NVME}p1" ]; then
    TMPBOOT=$(mktemp -d)   # intentionally NOT in MOUNTS_TO_CLEAN — we umount explicitly
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
    reboot
fi

# ── 6. Flash NVMe from USB cache ──────────────────────────────────────────────
log "Flashing NVMe from USB (version $USB_VER)..."
zstd -dc "$USB_IMG" | dd of="$NVME" bs=4M conv=fsync status=progress
sync
partprobe "$NVME"
udevadm settle --timeout=10

# Wipe the version stamp BEFORE repartition.
# If repartition fails, NVME_VER reads as 0 on next boot → re-flash triggered.
TMPBOOT=$(mktemp -d)
mount "${NVME}p1" "$TMPBOOT"
rm -f "$TMPBOOT/node-img.ver"
sed -i 's| init=/usr/lib/raspi-config/init_resize\.sh||g' "$TMPBOOT/cmdline.txt" 2>/dev/null || true
umount "$TMPBOOT"
rm -rf "$TMPBOOT"

# ── 7. Repartition NVMe ───────────────────────────────────────────────────────
log "Resizing root partition to $ROOT_SIZE..."
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

# Create the mount point on NVMe root (no fstab entry — systemd mount unit handles mounting)
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
```

**Key properties:**
- **USB-authoritative:** Network updates USB cache; USB flashes NVMe. Never network → NVMe directly.
- **Network-optional:** Operates from USB cache alone when Monolith unreachable.
- **Idempotent:** Reboots immediately if NVMe matches USB version.
- **Boot-loop protected:** After 3 consecutive failures, drops to a shell.
- **Safe repartition:** Version stamp wiped before repartition — a mid-repartition failure causes re-flash on next boot, not a boot into a broken NVMe.
- **No fstab conflict:** Does not write a fstab entry for p3; the systemd mount unit (baked into Node IMG) is the sole mechanism.
- **Persistent logging:** Appends to `node-image/bootstrap.log` on identity USB.

---

## 9. Image Versioning

**Format:** Unix epoch integer (e.g. `1744272000`). Plain text, one line.

```json
{
  "current_version": 1744272000,
  "image_file": "rpi-node-1744272000.img.zst",
  "image_sha256": "abcdef1234...",
  "image_size_bytes": 1500000000,
  "published_at": "2026-04-09T18:00:00Z"
}
```

`current_version` is an integer for direct bash `-gt` / `-ge` / `-le` comparisons.

---

## 10. Compression — zstd

**zstd level 19** for Node IMG distribution.

| Format | Decompression on A76 | Compressed size | Flash bottleneck |
|--------|---------------------|-----------------|------------------|
| XZ | ~37–43 MB/s | ~1.2–1.5 GB | XZ CPU — rejected |
| gzip | ~150–200 MB/s | ~1.8–2.0 GB | USB read speed |
| **zstd -19** | **~500 MB/s** | **~1.4–1.8 GB** | USB read speed |

XZ decompression at 37–43 MB/s on Cortex-A76 is the bottleneck — well below USB 3.0 read speeds. zstd removes this bottleneck at similar compression ratios.

---

## 11. Monolith Infrastructure

### Directory layout

```
/mnt/App-Storage/Container-Data/k3s-control-plane/
├── docker-compose.yml
├── nginx.conf
├── images/
│   ├── node/
│   │   ├── manifest.json
│   │   ├── rpi-node-latest.img.zst  → rpi-node-<EPOCH>.img.zst
│   │   └── rpi-node-<EPOCH>.img.zst
│   └── bootstrap/
│       └── rpi-bootstrap.img
├── tftp/          (retained until cluster is stable, then remove)
└── kubeconfig/
```

**One-time setup (before first CI run):**
```bash
ssh truenas_admin@192.168.10.247 \
    "mkdir -p /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}"
```

### `nginx.conf`

```nginx
server {
    listen 8080;
    root /srv/images;
    autoindex on;
    sendfile on;
    tcp_nopush on;

    location ~* \.img\.zst$ {
        gzip off;
        add_header Content-Type application/octet-stream;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

---

## 12. Packer Builds

### 12.1 Node IMG — `rpi-node.pkr.hcl`

Complete provisioner sequence (order matters):

1. **Create `owner` user** — Pi OS ships `pi`; `owner` must be explicitly created:
   ```bash
   useradd -m -s /bin/bash -G sudo owner
   echo 'owner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/owner
   chmod 440 /etc/sudoers.d/owner
   ```

2. **Add SSH authorized key** for `owner`:
   ```bash
   mkdir -p /home/owner/.ssh
   echo '${var.ssh_public_key}' > /home/owner/.ssh/authorized_keys
   chmod 700 /home/owner/.ssh
   chmod 600 /home/owner/.ssh/authorized_keys
   chown -R owner:owner /home/owner/.ssh
   ```

3. **Delete `pi` user** (security):
   ```bash
   userdel -r pi || true
   ```

4. **Install packages**: `apt-get install -y curl jq git nfs-common open-iscsi zstd`

5. **Purge cloud-init**:
   ```bash
   apt-get purge -y cloud-init
   rm -rf /etc/cloud /var/lib/cloud
   ```

6. **Install k3s** (units created, not enabled):
   ```bash
   curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
   chmod +x /tmp/k3s-install.sh
   INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true /tmp/k3s-install.sh
   rm /tmp/k3s-install.sh
   ```

7. **Write version stamp**:
   ```bash
   echo '${var.image_version}' > /boot/firmware/node-img.ver
   ```

8. **Update `config.txt`** (append to `[pi5]` section):
   ```bash
   # Ensure [pi5] section exists and add NVMe boot entries
   grep -q '\[pi5\]' /boot/firmware/config.txt \
       || echo '[pi5]' >> /boot/firmware/config.txt
   cat >> /boot/firmware/config.txt <<'EOF'
   kernel=kernel_2712.img
   auto_initramfs=1
   dtparam=pciex1
   dtparam=nvme
   EOF
   ```

9. **cgroup params in `cmdline.txt`** (keep from existing):
   ```bash
   sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
   ```

10. **Disable root auto-expansion** (keep from existing):
    ```bash
    sed -i 's| init=/usr/lib/raspi-config/init_resize\.sh||g' /boot/firmware/cmdline.txt
    systemctl disable raspberrypi-sys-mods-firstboot.service || true
    systemctl disable resize2fs_once.service || true
    ```

11. **Install systemd units** via `file` provisioners + `systemctl enable`:
    - `apply-identity.service` + `apply-identity.sh`
    - `detect-node-storage.service` + `detect-node-storage.sh`
    - `mnt-node-storage.mount`

12. **Create `/mnt/node-storage`**:
    ```bash
    mkdir -p /mnt/node-storage
    ```

### 12.2 Bootstrap IMG — `rpi-bootstrap.pkr.hcl`

```hcl
source "arm-image" "rpi_bootstrap" {
  iso_url           = var.image_url
  iso_checksum      = var.image_checksum
  image_type        = "raspberrypi"
  qemu_binary       = "qemu-aarch64-static"
  image_mounts      = ["/boot/firmware", "/"]
  target_image_size = 2147483648   # 2 GB
  output_filename   = "output/rpi-bootstrap.img"
  resolv-conf       = "copy-host"
}
```

Provisioners:
1. `apt-get install -y curl jq parted e2fsprogs dosfstools util-linux zstd`
2. Copy `bootstrap.sh` → `/usr/local/bin/bootstrap.sh` (chmod +x)
3. Install and enable `hyperion-bootstrap.service` (Type=oneshot, After=network-online.target)
4. Disable: bluetooth, avahi-daemon, triggerhappy

---

## 13. CI/CD — GitHub Actions

### SSH Deploy Key (one-time Monolith setup)

The CI deploy key must be **restricted** to the images directory. Use `rrsync` (ships with rsync) for file transfers, and a separate restricted handler for manifest/symlink updates:

```bash
# On Monolith — create restricted deploy handler
cat > /usr/local/bin/ci-deploy-handler.sh << 'EOF'
#!/bin/bash
# Restricts CI SSH key to safe operations on the images directory
IMAGES="/mnt/Media-Storage/Infra-Storage/images"
case "$SSH_ORIGINAL_COMMAND" in
    rsync\ --server*)
        # rrsync handles path restriction
        exec /usr/bin/rrsync "$IMAGES"
        ;;
    update-manifest\ node\ *)
        # Validate and write manifest.json
        DATA="${SSH_ORIGINAL_COMMAND#update-manifest node }"
        echo "$DATA" | jq . > "$IMAGES/node/manifest.json.tmp" \
            && mv "$IMAGES/node/manifest.json.tmp" "$IMAGES/node/manifest.json"
        ;;
    update-symlink\ node\ *)
        TARGET="${SSH_ORIGINAL_COMMAND#update-symlink node }"
        [[ "$TARGET" =~ ^rpi-node-[0-9]+\.img\.zst$ ]] \
            && ln -sf "$TARGET" "$IMAGES/node/rpi-node-latest.img.zst"
        ;;
    prune-node-images)
        find "$IMAGES/node" -name 'rpi-node-[0-9]*.img.zst' \
            | sort -t- -k3 -n | head -n -2 | xargs -r rm -f
        ;;
    *)
        echo "Rejected: $SSH_ORIGINAL_COMMAND" >&2; exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/ci-deploy-handler.sh

# Generate deploy key
ssh-keygen -t ed25519 -f ~/.ssh/hyperion_ci_deploy -N "" -C "github-actions-ci"

# Add to authorized_keys with restriction
echo "command=\"/usr/local/bin/ci-deploy-handler.sh\",restrict $(cat ~/.ssh/hyperion_ci_deploy.pub)" \
    >> ~/.ssh/authorized_keys

# Add Monolith host key to known_hosts file for CI
ssh-keyscan -H 192.168.10.247 > /tmp/monolith_known_hosts
# Add content of /tmp/monolith_known_hosts as MONOLITH_HOST_KEY GitHub secret
```

### Workflow: Node IMG

```yaml
# .github/workflows/build-node-img.yml
name: Build and publish Node IMG

on:
  push:
    branches: [main]
    paths:
      - 'Hyperion/packer/rpi-node.pkr.hcl'
      - 'Hyperion/packer/files/**'
  workflow_dispatch:

concurrency:
  group: deploy-to-monolith
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 120

    steps:
      - uses: actions/checkout@v4

      - name: Cache Pi OS base image
        uses: actions/cache@v4
        with:
          path: ~/.packer-cache
          key: pios-${{ hashFiles('Hyperion/packer/rpi-node.pkr.hcl') }}

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq qemu-user-static binfmt-support zstd curl jq

      - name: Register QEMU binfmt
        run: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

      - name: Install Packer
        run: |
          curl -fsSL https://apt.releases.hashicorp.com/gpg \
            | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
          echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
            | sudo tee /etc/apt/sources.list.d/hashicorp.list
          sudo apt-get update -qq && sudo apt-get install -y -qq packer
          packer plugins install github.com/solo-io/arm-image

      - name: Generate version
        run: echo "VERSION=$(date +%s)" >> $GITHUB_ENV

      - name: Build Node IMG
        working-directory: Hyperion/packer
        run: |
          packer build \
            -var "image_version=${{ env.VERSION }}" \
            -var "ssh_public_key=${{ secrets.NODE_SSH_PUBLIC_KEY }}" \
            rpi-node.pkr.hcl

      - name: Compress with zstd
        run: |
          IMG_FILE="rpi-node-${{ env.VERSION }}.img.zst"
          echo "IMG_FILE=$IMG_FILE" >> $GITHUB_ENV
          zstd -19 -T0 Hyperion/packer/output/rpi-node.img -o "$IMG_FILE"
          echo "IMG_SHA256=$(sha256sum "$IMG_FILE" | awk '{print $1}')" >> $GITHUB_ENV
          echo "IMG_SIZE=$(stat -c%s "$IMG_FILE")" >> $GITHUB_ENV

      - name: Write SSH known_hosts
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.MONOLITH_HOST_KEY }}" > ~/.ssh/known_hosts
          chmod 600 ~/.ssh/known_hosts

      - name: Write deploy key
        run: |
          printf '%s\n' "${{ secrets.MONOLITH_SSH_KEY }}" > /tmp/deploy_key
          chmod 600 /tmp/deploy_key

      - name: Publish image to Monolith
        run: |
          rsync -av -e "ssh -i /tmp/deploy_key" \
            "${{ env.IMG_FILE }}" \
            "truenas_admin@${{ secrets.MONOLITH_HOST }}:."

      - name: Update manifest and symlink
        run: |
          MANIFEST=$(jq -n \
            --argjson ver "${{ env.VERSION }}" \
            --arg file "${{ env.IMG_FILE }}" \
            --arg sha "${{ env.IMG_SHA256 }}" \
            --argjson size "${{ env.IMG_SIZE }}" \
            --arg ts "$(date -Iseconds)" \
            '{current_version:$ver,image_file:$file,image_sha256:$sha,image_size_bytes:$size,published_at:$ts}')
          ssh -i /tmp/deploy_key "truenas_admin@${{ secrets.MONOLITH_HOST }}" \
            "update-manifest node $MANIFEST"
          ssh -i /tmp/deploy_key "truenas_admin@${{ secrets.MONOLITH_HOST }}" \
            "update-symlink node ${{ env.IMG_FILE }}"
          ssh -i /tmp/deploy_key "truenas_admin@${{ secrets.MONOLITH_HOST }}" \
            "prune-node-images"

      - name: Cleanup
        if: always()
        run: rm -f /tmp/deploy_key
```

### Workflow: Bootstrap IMG

```yaml
# .github/workflows/build-bootstrap-img.yml
name: Build Bootstrap IMG

on:
  push:
    branches: [main]
    paths:
      - 'Hyperion/packer/rpi-bootstrap.pkr.hcl'
      - 'Hyperion/packer/files/bootstrap.sh'
      - 'Hyperion/packer/files/bootstrap.service'
  workflow_dispatch:

concurrency:
  group: deploy-to-monolith
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
      # (same QEMU + Packer setup as Node IMG workflow)
      - name: Build Bootstrap IMG
        working-directory: Hyperion/packer
        run: packer build rpi-bootstrap.pkr.hcl

      - name: Write SSH known_hosts and deploy key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.MONOLITH_HOST_KEY }}" > ~/.ssh/known_hosts
          printf '%s\n' "${{ secrets.MONOLITH_SSH_KEY }}" > /tmp/deploy_key
          chmod 600 ~/.ssh/known_hosts /tmp/deploy_key

      - name: Publish to Monolith
        run: |
          rsync -av -e "ssh -i /tmp/deploy_key" \
            Hyperion/packer/output/rpi-bootstrap.img \
            "truenas_admin@${{ secrets.MONOLITH_HOST }}:."

      - name: Cleanup
        if: always()
        run: rm -f /tmp/deploy_key
```

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `MONOLITH_SSH_KEY` | Ed25519 private key (from `hyperion_ci_deploy`) |
| `MONOLITH_HOST_KEY` | Output of `ssh-keyscan -H 192.168.10.247` |
| `MONOLITH_HOST` | `192.168.10.247` |
| `NODE_SSH_PUBLIC_KEY` | SSH public key baked into Node IMG for `owner` |

---

## 14. Re-imaging Workflow

### Full cluster re-image

```
1. Push Packer changes → CI builds and publishes automatically

2. For each node (SSH to reachable nodes; power-cycle the rest):
   a. Insert Bootstrap SD card + verify identity USB is present
   b. ssh -o BatchMode=yes owner@192.168.10.10X "sudo reboot"
      or: ./Hyperion/reimage.sh all

3. Each node: downloads to USB cache (if newer) → flashes NVMe → reboots into NVMe

4. Verify all nodes are up:
   for ip in 192.168.10.{101..110}; do
       ssh -o ConnectTimeout=10 -o BatchMode=yes owner@$ip hostname 2>/dev/null \
           && echo "$ip: OK" || echo "$ip: unreachable"
   done
```

### Before re-imaging a live cluster node

```bash
kubectl drain hyperion-alpha --ignore-daemonsets --delete-emptydir-data
ssh owner@192.168.10.101 "sudo reboot"
kubectl uncordon hyperion-alpha   # after node rejoins
```

### Node rescue (broken NVMe — no network needed)

Insert Bootstrap SD + identity USB (with cached image) → power-cycle. Bootstrap detects NVMe at version 0, flashes from USB cache, reboots into fresh NVMe.

---

## 15. Operator Workflow — End to End

### Pre-deployment (one-time, before any node is powered on)

```
1. Add GitHub secrets (see §13 table)
   Set up CI deploy key on Monolith (see §13 — ci-deploy-handler.sh + authorized_keys)
   Create image directories on Monolith:
     ssh truenas_admin@192.168.10.247 \
       "mkdir -p /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}"

2. Update EEPROM firmware on all nodes (requires a Pi OS SD card — stock Pi OS works):
     sudo rpi-eeprom-update -a && sudo reboot

3. Configure EEPROM BOOT_ORDER + BOOT_UART on all nodes:
     ./Hyperion/configure-eeprom.sh --boot-order 0xf61 --user owner --reboot
   ⚠ Do this BEFORE inserting Bootstrap SD cards. EEPROM configuration
     uses SSH to the running node OS, not the Bootstrap environment.
```

### Initial cluster bring-up

```
4. Push to main → CI builds Node IMG and Bootstrap IMG → published to Monolith
   (Or first-run manual: build locally with packer build + publish-image.sh)

5. Download and flash Bootstrap SD card (one card works for all nodes):
     curl http://192.168.10.247:50011/bootstrap/rpi-bootstrap.img \
       | sudo dd of=/dev/sdX bs=4M status=progress

6. Prepare identity USB sticks — one per node, per-node hostname:
     ./Hyperion/flash-identity-usb.sh /dev/sdY hyperion-alpha
   (repeat for all 10 nodes)

7. Insert identity USB + Bootstrap SD into each Pi (before power-on).
   Power on all nodes.
   → Bootstrap downloads Node IMG to USB cache → flashes NVMe → reboots into NVMe
   → First NVMe boot: apply-identity.service sets hostname

8. Verify all nodes are reachable:
     for ip in 192.168.10.{101..110}; do
         ssh -o ConnectTimeout=10 -o BatchMode=yes owner@$ip hostname 2>/dev/null \
             && echo "$ip: OK" || echo "$ip: unreachable"
     done

9. Run Ansible bootstrap:
     cd Hyperion/ansible && ansible-playbook bootstrap.yml

10. Bootstrap FluxCD.
```

---

## 16. Files to Create / Modify

| Path | Action | Notes |
|------|--------|-------|
| `.github/workflows/build-node-img.yml` | **Create** | CI: build + publish Node IMG |
| `.github/workflows/build-bootstrap-img.yml` | **Create** | CI: build + publish Bootstrap IMG |
| `Hyperion/packer/rpi-node.pkr.hcl` | **Create** (revise from `rpi-base.pkr.hcl`) | Node IMG build |
| `Hyperion/packer/rpi-bootstrap.pkr.hcl` | **Create** | Bootstrap SD IMG build |
| `Hyperion/packer/files/apply-identity.sh` | **Create** | Hostname-from-USB script |
| `Hyperion/packer/files/apply-identity.service` | **Create** | systemd unit |
| `Hyperion/packer/files/detect-node-storage.sh` | **Create** | USB HDD detection |
| `Hyperion/packer/files/detect-node-storage.service` | **Create** | systemd unit |
| `Hyperion/packer/files/mnt-node-storage.mount` | **Create** | systemd mount unit |
| `Hyperion/packer/files/bootstrap.sh` | **Create** | Bootstrap main script |
| `Hyperion/packer/files/bootstrap.service` | **Create** | Bootstrap systemd unit |
| `Hyperion/flash-identity-usb.sh` | **Create** | Formats per-node identity USB |
| `Hyperion/reimage.sh` | **Create** | SSH-based re-image trigger |
| `Hyperion/publish-image.sh` | **Create** | Local build → compress → publish (for first run before CI) |
| `Monolith/k3s-control-plane/nginx.conf` | **Update** | sendfile, zst content-type, gzip off |
| `Hyperion/configure-eeprom.sh` | **Update** | Default `0xf612` → `0xf61`; add `BOOT_UART=1` support |
| `Hyperion/ansible/bootstrap.yml` | **Update** | Remove hostname task (handled by apply-identity.service) |
| `docs/todo.md` | **Update** | Replace netboot steps with new workflow |
| `.gitignore` | **Verify** | Confirm `Hyperion/packer/output/` is excluded |
| `Hyperion/packer/rpi-base.pkr.hcl` | **Delete** | Superseded by rpi-node.pkr.hcl |
| `Monolith/k3s-control-plane/netboot/` | **Delete** | No longer needed |
| `Hyperion/cloud-init/` | **Archive/Delete** | Superseded by identity USB |

---

## 17. Decisions

| Question | Decision |
|----------|----------|
| PCIe Gen | **Gen 3** (`dtparam=pciex1_gen=3`) |
| Pi OS base image versioning | **Pin** — manually update URL + checksum in `rpi-node.pkr.hcl`, test on one node before rolling out |

**All questions resolved. Document is implementation-ready.**
