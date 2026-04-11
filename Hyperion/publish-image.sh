#!/usr/bin/env bash
# publish-image.sh
# Builds a Node IMG or Bootstrap IMG locally with Packer and publishes it as a
# GitHub Release. The ci-deploy container on Monolith will detect and download it.
#
# Prerequisites:
#   - packer installed (https://developer.hashicorp.com/packer/install)
#   - packer plugin: packer plugins install github.com/solo-io/arm-image
#   - qemu-aarch64-static + binfmt-support (sudo apt-get install qemu-user-static binfmt-support)
#   - docker (for: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes)
#   - zstd (for node image compression)
#   - gh CLI authenticated (gh auth login)
#   - NODE_SSH_PUBLIC_KEY environment variable set (for node image builds)
#
# Usage:
#   ./publish-image.sh node                # build and publish Node IMG
#   ./publish-image.sh bootstrap           # build and publish Bootstrap IMG
#   ./publish-image.sh node --dry-run      # build only, skip GitHub Release
set -euo pipefail

PACKER_DIR="$(cd "$(dirname "$0")/packer" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <node|bootstrap> [--dry-run]"
    echo ""
    echo "  node            Build and publish the Node IMG"
    echo "  bootstrap       Build and publish the Bootstrap IMG"
    echo "  --dry-run       Build only — skip GitHub Release creation"
    echo ""
    echo "Environment variables:"
    echo "  NODE_SSH_PUBLIC_KEY   SSH public key baked into the Node IMG (required for 'node')"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
[ $# -ge 1 ] || usage

IMAGE_TYPE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        node|bootstrap) IMAGE_TYPE="$1" ;;
        --dry-run)      DRY_RUN=true ;;
        *)              die "Unknown argument: $1" ;;
    esac
    shift
done

[ -n "$IMAGE_TYPE" ] || usage

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v packer >/dev/null || die "packer not found. See: https://developer.hashicorp.com/packer/install"
command -v docker >/dev/null || die "docker not found"
command -v gh     >/dev/null || die "gh CLI not found. See: https://cli.github.com"

if [ "$IMAGE_TYPE" = "node" ]; then
    command -v zstd >/dev/null || die "zstd not found. Install: sudo apt-get install zstd"
    [ -n "${NODE_SSH_PUBLIC_KEY:-}" ] \
        || die "NODE_SSH_PUBLIC_KEY is not set. Export the public key before running."
fi

if [ "$DRY_RUN" = false ]; then
    gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated. Run: gh auth login"
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
    (cd "$PACKER_DIR" && sudo packer build \
        -var "image_version=$VERSION" \
        -var "ssh_public_key=${NODE_SSH_PUBLIC_KEY}" \
        rpi-node.pkr.hcl)

    RAW_IMG="$PACKER_DIR/output/rpi-node.img"
    [ -f "$RAW_IMG" ] || die "Packer build completed but $RAW_IMG not found"

    log "Compressing with zstd -19..."
    IMG_FILE="rpi-node-${VERSION}.img.zst"
    zstd -19 -T0 "$RAW_IMG" -o "$IMG_FILE"
    IMG_SHA256=$(sha256sum "$IMG_FILE" | awk '{print $1}')
    log "  File  : $IMG_FILE"
    log "  SHA256: $IMG_SHA256"

    if [ "$DRY_RUN" = true ]; then
        log "Dry run — skipping GitHub Release. Image at: $IMG_FILE"
        exit 0
    fi

    log "Creating GitHub Release node-v${VERSION}..."
    gh release create "node-v${VERSION}" \
        --title "Node IMG v${VERSION}" \
        --notes "SHA256: ${IMG_SHA256}" \
        "$IMG_FILE"

    rm -f "$IMG_FILE"
    log "Published. The ci-deploy container on Monolith will download it within $(( POLL_INTERVAL / 60 )) minutes."

elif [ "$IMAGE_TYPE" = "bootstrap" ]; then
    log "Building Bootstrap IMG..."
    (cd "$PACKER_DIR" && sudo packer build rpi-bootstrap.pkr.hcl)

    RAW_IMG="$PACKER_DIR/output/rpi-bootstrap.img"
    [ -f "$RAW_IMG" ] || die "Packer build completed but $RAW_IMG not found"

    if [ "$DRY_RUN" = true ]; then
        log "Dry run — skipping GitHub Release. Image at: $RAW_IMG"
        exit 0
    fi

    log "Compressing with zstd -19..."
    COMPRESSED_IMG="${RAW_IMG%.img}.img.zst"
    zstd -19 -T0 "$RAW_IMG" -o "$COMPRESSED_IMG"

    log "Publishing Bootstrap IMG as bootstrap-latest release..."
    gh release delete bootstrap-latest --yes --cleanup-tag 2>/dev/null || true
    gh release create bootstrap-latest \
        --title "Bootstrap IMG (latest)" \
        --notes "Bootstrap SD card image. Rebuilt automatically on changes." \
        --prerelease \
        "$COMPRESSED_IMG"

    log "Published. The ci-deploy container on Monolith will download it within ${POLL_INTERVAL:-300} seconds."
fi
