#!/usr/bin/env bash
# publish-image.sh
# Builds a Node IMG or Bootstrap IMG locally with Packer and publishes it to Monolith.
# Use this for manual builds before GitHub Actions CI is wired up, or for one-off
# out-of-band publishes.
#
# Prerequisites:
#   - packer installed (https://developer.hashicorp.com/packer/install)
#   - packer plugin: packer plugins install github.com/solo-io/arm-image
#   - qemu-aarch64-static + binfmt-support (sudo apt-get install qemu-user-static binfmt-support)
#   - docker (for: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes)
#   - zstd (for node image compression)
#   - SSH access to Monolith (key-based, user truenas_admin)
#   - NODE_SSH_PUBLIC_KEY environment variable set (for node image builds)
#
# Usage:
#   ./publish-image.sh node                # build and publish Node IMG
#   ./publish-image.sh bootstrap           # build and publish Bootstrap IMG
#   ./publish-image.sh node --dry-run      # build only, skip upload
#   ./publish-image.sh node --monolith <host>  # override Monolith host (default: 192.168.10.247)
set -euo pipefail

MONOLITH_HOST="${MONOLITH_HOST:-192.168.10.247}"
MONOLITH_USER="truenas_admin"
PACKER_DIR="$(cd "$(dirname "$0")/packer" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <node|bootstrap> [--dry-run] [--monolith <host>]"
    echo ""
    echo "  node            Build and publish the Node IMG"
    echo "  bootstrap       Build and publish the Bootstrap IMG"
    echo "  --dry-run       Build only — skip upload to Monolith"
    echo "  --monolith <h>  Override Monolith host (default: 192.168.10.247)"
    echo ""
    echo "Environment variables:"
    echo "  NODE_SSH_PUBLIC_KEY   SSH public key baked into the Node IMG (required for 'node')"
    echo "  MONOLITH_HOST         Monolith hostname/IP (can also be set via --monolith)"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
[ $# -ge 1 ] || usage

IMAGE_TYPE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        node|bootstrap)
            IMAGE_TYPE="$1"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --monolith)
            shift
            [ $# -gt 0 ] || die "--monolith requires a host argument"
            MONOLITH_HOST="$1"
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
    shift
done

[ -n "$IMAGE_TYPE" ] || usage

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v packer  >/dev/null || die "packer not found. See: https://developer.hashicorp.com/packer/install"
command -v docker  >/dev/null || die "docker not found"
command -v zstd    >/dev/null || die "zstd not found. Install: sudo apt-get install zstd"

if [ "$IMAGE_TYPE" = "node" ]; then
    [ -n "${NODE_SSH_PUBLIC_KEY:-}" ] \
        || die "NODE_SSH_PUBLIC_KEY is not set. Export the public key before running."
fi

# ── Register QEMU binfmt handlers ─────────────────────────────────────────────
log "Registering QEMU binfmt handlers..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# ── Generate version ──────────────────────────────────────────────────────────
VERSION=$(date +%s)
log "Build version: $VERSION"

# ── Build ─────────────────────────────────────────────────────────────────────
mkdir -p "$PACKER_DIR/output"

if [ "$IMAGE_TYPE" = "node" ]; then
    log "Building Node IMG..."
    (cd "$PACKER_DIR" && packer build \
        -var "image_version=$VERSION" \
        -var "ssh_public_key=${NODE_SSH_PUBLIC_KEY}" \
        rpi-node.pkr.hcl)

    RAW_IMG="$PACKER_DIR/output/rpi-node.img"
    [ -f "$RAW_IMG" ] || die "Packer build completed but $RAW_IMG not found"

    log "Compressing with zstd -19..."
    IMG_FILE="rpi-node-${VERSION}.img.zst"
    zstd -19 -T0 "$RAW_IMG" -o "$IMG_FILE"
    IMG_SHA256=$(sha256sum "$IMG_FILE" | awk '{print $1}')
    IMG_SIZE=$(stat -c%s "$IMG_FILE")
    log "  File  : $IMG_FILE"
    log "  SHA256: $IMG_SHA256"
    log "  Size  : $IMG_SIZE bytes"

    if [ "$DRY_RUN" = true ]; then
        log "Dry run — skipping upload."
        exit 0
    fi

    log "Uploading $IMG_FILE to Monolith..."
    rsync -av -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$IMG_FILE" \
        "${MONOLITH_USER}@${MONOLITH_HOST}:."

    log "Updating manifest and symlink on Monolith..."
    MANIFEST=$(jq -n \
        --argjson ver  "$VERSION" \
        --arg     file "$IMG_FILE" \
        --arg     sha  "$IMG_SHA256" \
        --argjson size "$IMG_SIZE" \
        --arg     ts   "$(date -Iseconds)" \
        '{current_version:$ver,image_file:$file,image_sha256:$sha,image_size_bytes:$size,published_at:$ts}')
    ssh -o StrictHostKeyChecking=accept-new "${MONOLITH_USER}@${MONOLITH_HOST}" \
        "update-manifest node $MANIFEST"
    ssh -o StrictHostKeyChecking=accept-new "${MONOLITH_USER}@${MONOLITH_HOST}" \
        "update-symlink node $IMG_FILE"
    ssh -o StrictHostKeyChecking=accept-new "${MONOLITH_USER}@${MONOLITH_HOST}" \
        "prune-node-images"

    rm -f "$IMG_FILE"

elif [ "$IMAGE_TYPE" = "bootstrap" ]; then
    log "Building Bootstrap IMG..."
    (cd "$PACKER_DIR" && packer build rpi-bootstrap.pkr.hcl)

    RAW_IMG="$PACKER_DIR/output/rpi-bootstrap.img"
    [ -f "$RAW_IMG" ] || die "Packer build completed but $RAW_IMG not found"

    if [ "$DRY_RUN" = true ]; then
        log "Dry run — skipping upload. Image at: $RAW_IMG"
        exit 0
    fi

    log "Uploading Bootstrap IMG to Monolith..."
    rsync -av -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$RAW_IMG" \
        "${MONOLITH_USER}@${MONOLITH_HOST}:."
fi

echo ""
log "Published $IMAGE_TYPE image (version $VERSION) to $MONOLITH_HOST."
