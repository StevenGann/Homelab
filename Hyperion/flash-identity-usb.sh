#!/usr/bin/env bash
# flash-identity-usb.sh
# Formats a USB stick as ext4 (label HYPERION-ID) and writes per-node identity
# for the NixOS-based Hyperion cluster (schema version 2).
#
# Run this once per node before first install, or whenever a USB stick is
# replaced.
#
# Usage:
#   ./flash-identity-usb.sh <device> <hostname>
#   ./flash-identity-usb.sh /dev/sdb hyperion-alpha
#
# The device will be completely erased. Double-check the device path
# before running.
#
# What lands on the USB (schema v2):
#   /identity.env          — copied verbatim from nixos/identity-overrides/<hostname>.env
#   /age-key.txt           — per-node age private key (generated on first flash)
#   /secrets/
#     ssh_host_ed25519_key       — generated on first flash, persists across NVMe re-flashes
#     ssh_host_ed25519_key.pub   — corresponding public key
#   /meta/
#     schema-version             — "2"
#     generated-utc              — ISO-8601 timestamp
#
# The age private key is the per-node sops-nix decryption key. The public
# half must be added to Hyperion/.sops.yaml's creation_rules so that
# nixos/secrets/common.yaml can be re-encrypted to include this node.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_VERSION="2"

usage() {
    echo "Usage: $0 <device> <hostname>"
    echo ""
    echo "  device    Block device to format (e.g. /dev/sdb).  WILL BE ERASED."
    echo "  hostname  Hostname (e.g. hyperion-alpha)."
    echo ""
    echo "Examples:"
    echo "  $0 /dev/sdb hyperion-alpha"
    echo "  $0 /dev/sdc hyperion-beta"
    echo ""
    echo "Prerequisites (one-time setup):"
    echo "  - mkfs.ext4 (e2fsprogs)"
    echo "  - age (https://github.com/FiloSottile/age)"
    echo "  - ssh-keygen (openssh)"
    echo "  - The hostname must have a matching identity-override at"
    echo "    nixos/identity-overrides/<hostname>.env."
    echo ""
    echo "Run order on a fresh USB:"
    echo "  1. ./flash-identity-usb.sh /dev/sdX hyperion-alpha"
    echo "  2. Note the printed age public key."
    echo "  3. Add the age public key to Hyperion/.sops.yaml creation_rules."
    echo "  4. Re-encrypt nixos/secrets/common.yaml against the new key set:"
    echo "       sops updatekeys nixos/secrets/common.yaml"
    echo "  5. Commit the .sops.yaml and re-encrypted secrets."
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

ID_OVERRIDE="${REPO_ROOT}/nixos/identity-overrides/${HOSTNAME}.env"
[ -f "$ID_OVERRIDE" ] \
    || die "Identity override not found at ${ID_OVERRIDE}.\n  Add the per-node .env file before flashing."

# ── Prerequisite tooling ──────────────────────────────────────────────────────
command -v mkfs.ext4   >/dev/null || die "mkfs.ext4 not found. Install e2fsprogs."
command -v age-keygen  >/dev/null || die "age-keygen not found. Install age (https://github.com/FiloSottile/age)."
command -v ssh-keygen  >/dev/null || die "ssh-keygen not found. Install openssh."

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
warn "This will ERASE all data on $DEVICE."
echo -e "  Device         : ${CYAN}$DEVICE${NC}"
echo -e "  Label          : HYPERION-ID"
echo -e "  Host           : ${CYAN}$HOSTNAME${NC}"
echo -e "  Schema version : $SCHEMA_VERSION"
echo -e "  Source override: ${CYAN}$ID_OVERRIDE${NC}"
echo ""
read -r -p "Type YES to confirm: " confirm
[ "$confirm" = "YES" ] || { echo "Aborted."; exit 0; }
echo ""

# ── Unmount any existing partitions ──────────────────────────────────────────
log "Unmounting any mounted partitions on $DEVICE..."
for part in "${DEVICE}"?*; do
    if mount | grep -q "^$part "; then
        umount "$part" 2>/dev/null && log "  Unmounted $part" || warn "Could not unmount $part — continuing"
    fi
done

# ── Partition table: single ext4 partition ────────────────────────────────────
# ext4 (with noatime mount option on the Pi side) avoids vfat's filename-case
# limitations and exfat's lack of a journal. ext4 also handles the small
# secrets files efficiently — total payload is well under 1 MiB.
log "Writing partition table..."
wipefs -a "$DEVICE" >/dev/null 2>&1 || true
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart HYPERION-ID 1MiB 100%
udevadm settle --timeout=10

PARTITION="${DEVICE}1"
# Some devices use p1 suffix (e.g. /dev/mmcblk0p1)
[ -b "$PARTITION" ] || PARTITION="${DEVICE}p1"
[ -b "$PARTITION" ] || die "Partition ${DEVICE}1 / ${DEVICE}p1 not found after partitioning"

log "Formatting $PARTITION as ext4 (label HYPERION-ID)..."
mkfs.ext4 -F -L "HYPERION-ID" "$PARTITION"
udevadm settle --timeout=5

# ── Mount and stage payload ──────────────────────────────────────────────────
MNT=$(mktemp -d)
trap 'umount "$MNT" 2>/dev/null || true; rm -rf "$MNT"' EXIT

mount "$PARTITION" "$MNT"

log "Writing identity.env from override..."
install -m 0644 "$ID_OVERRIDE" "$MNT/identity.env"

log "Generating per-node age keypair..."
# age-keygen prints "Public key: age1..." on stderr; capture and re-emit.
install -d -m 0700 "$MNT"
age-keygen -o "$MNT/age-key.txt" 2>/tmp/age-pubkey.$$
chmod 0400 "$MNT/age-key.txt"
AGE_PUBKEY=$(grep -oE 'age1[a-z0-9]+' /tmp/age-pubkey.$$ | head -1)
rm -f /tmp/age-pubkey.$$
[ -n "$AGE_PUBKEY" ] || die "Failed to extract age public key — check age-keygen output."

log "Generating SSH host keypair (ed25519)..."
install -d -m 0700 "$MNT/secrets"
ssh-keygen -t ed25519 -N '' -C "$HOSTNAME-host" -f "$MNT/secrets/ssh_host_ed25519_key"
chmod 0600 "$MNT/secrets/ssh_host_ed25519_key"
chmod 0644 "$MNT/secrets/ssh_host_ed25519_key.pub"

log "Writing schema metadata..."
install -d -m 0755 "$MNT/meta"
echo "$SCHEMA_VERSION" > "$MNT/meta/schema-version"
date -u +%Y-%m-%dT%H:%M:%SZ > "$MNT/meta/generated-utc"

sync
umount "$MNT"
rm -rf "$MNT"
trap - EXIT

echo ""
log "Done. Identity USB is ready for $HOSTNAME."
echo ""
echo -e "  Label         : HYPERION-ID"
echo -e "  Hostname      : $HOSTNAME"
echo -e "  Schema version: $SCHEMA_VERSION"
echo -e "  Age pubkey    : ${CYAN}${AGE_PUBKEY}${NC}"
echo ""
warn "NEXT STEPS:"
echo "  1. Add the age public key to Hyperion/.sops.yaml creation_rules:"
echo ""
echo "       # for-${HOSTNAME}: $AGE_PUBKEY"
echo ""
echo "  2. Re-encrypt secrets against the new key set:"
echo "       cd Hyperion && sops updatekeys nixos/secrets/common.yaml"
echo ""
echo "  3. Commit the .sops.yaml and re-encrypted secrets."
echo ""
echo "  4. Insert this USB into the target Pi BEFORE powering on with the"
echo "     NVMe that has the Hyperion NixOS image flashed."
