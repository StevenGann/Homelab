#!/usr/bin/env bash
# poll.sh
# Polls GitHub Releases for new Hyperion images and downloads them to /images.
# Runs continuously inside the ci-deploy container.
#
# Environment variables:
#   GITHUB_REPO     Owner/repo slug (default: StevenGann/Homelab)
#   GITHUB_TOKEN    Personal access token (required for private repos, optional for public)
#   POLL_INTERVAL   Seconds between polls (default: 300)
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-StevenGann/Homelab}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
IMAGES_ROOT="/images"
GITHUB_API="https://api.github.com"

log()  { echo "[$(date '+%T')] [poll] $*"; }
warn() { echo "[$(date '+%T')] [poll] WARN: $*" >&2; }

# ── Authenticated curl wrappers ───────────────────────────────────────────────
api_get() {
    local url="$1"
    local args=(-sf -H "Accept: application/vnd.github+json")
    [ -n "${GITHUB_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl "${args[@]}" "$url"
}

download_asset() {
    local url="$1" dest="$2"
    local args=(-fL -H "Accept: application/octet-stream")
    [ -n "${GITHUB_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl "${args[@]}" "$url" -o "$dest"
}

# ── Node IMG ──────────────────────────────────────────────────────────────────
check_node() {
    log "Checking for new Node IMG..."

    local releases latest_release remote_version
    releases=$(api_get "$GITHUB_API/repos/$GITHUB_REPO/releases" 2>/dev/null) || {
        warn "GitHub API unreachable — skipping node check."
        return
    }

    latest_release=$(echo "$releases" \
        | jq '[.[] | select(.tag_name | test("^node-v[0-9]+$"))] | max_by(.tag_name | ltrimstr("node-v") | tonumber)')

    if [ -z "$latest_release" ] || [ "$latest_release" = "null" ]; then
        warn "No node-v* releases found yet."
        return
    fi

    remote_version=$(echo "$latest_release" | jq -r '.tag_name | ltrimstr("node-v")')

    local local_version=0
    [ -f "$IMAGES_ROOT/node/manifest.json" ] \
        && local_version=$(jq -r '.current_version // 0' "$IMAGES_ROOT/node/manifest.json" 2>/dev/null || echo 0)

    log "Node IMG: local=$local_version  remote=$remote_version"

    if (( remote_version <= local_version )); then
        log "Node IMG is current."
        return
    fi

    # Find the .img.zst asset
    local asset_name asset_url asset_size
    asset_name=$(echo "$latest_release" | jq -r '[.assets[] | select(.name | endswith(".img.zst"))] | first | .name')
    asset_url=$(echo "$latest_release"  | jq -r '[.assets[] | select(.name | endswith(".img.zst"))] | first | .url')
    asset_size=$(echo "$latest_release" | jq -r '[.assets[] | select(.name | endswith(".img.zst"))] | first | .size')

    if [ -z "$asset_name" ] || [ "$asset_name" = "null" ]; then
        warn "No .img.zst asset in release node-v${remote_version}."
        return
    fi

    # Extract SHA256 from release body ("SHA256: <hex>")
    local sha256
    sha256=$(echo "$latest_release" | jq -r '.body' \
        | grep '^SHA256: ' | cut -d' ' -f2 | tr -d '[:space:]' || true)

    log "Downloading $asset_name..."
    local dest_tmp="$IMAGES_ROOT/node/${asset_name}.tmp"
    download_asset "$asset_url" "$dest_tmp" || {
        warn "Download failed."
        rm -f "$dest_tmp"
        return
    }

    # Verify SHA256
    if [ -n "$sha256" ]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest_tmp" | awk '{print $1}')
        if [ "$actual_sha" != "$sha256" ]; then
            warn "SHA256 mismatch! Expected $sha256, got $actual_sha. Aborting."
            rm -f "$dest_tmp"
            return
        fi
        log "SHA256 verified."
    else
        warn "No SHA256 in release body — skipping verification."
    fi

    # Commit image
    mv "$dest_tmp" "$IMAGES_ROOT/node/$asset_name"

    # Write manifest (same format bootstrap.sh reads)
    cat > "$IMAGES_ROOT/node/manifest.json" <<EOF
{
  "current_version": $remote_version,
  "image_file": "$asset_name",
  "image_sha256": "${sha256:-unknown}",
  "image_size_bytes": $asset_size,
  "published_at": "$(date -Iseconds)"
}
EOF

    # Update symlink
    ln -sf "$asset_name" "$IMAGES_ROOT/node/rpi-node-latest.img.zst"

    # Keep only the 3 most recent .img.zst files
    ls -t "$IMAGES_ROOT"/node/*.img.zst 2>/dev/null | tail -n +4 | xargs -r rm -f

    log "Node IMG updated to version $remote_version."
}

# ── Bootstrap IMG ─────────────────────────────────────────────────────────────
check_bootstrap() {
    log "Checking for new Bootstrap IMG..."

    local release
    release=$(api_get "$GITHUB_API/repos/$GITHUB_REPO/releases/tags/bootstrap-latest" 2>/dev/null) || {
        warn "bootstrap-latest release not found or GitHub API unreachable."
        return
    }

    local remote_id local_id
    remote_id=$(echo "$release" | jq -r '.id')

    local marker="$IMAGES_ROOT/bootstrap/.release_id"
    local_id=""
    [ -f "$marker" ] && local_id=$(cat "$marker")

    if [ "$remote_id" = "$local_id" ]; then
        log "Bootstrap IMG is current."
        return
    fi

    local asset_url
    asset_url=$(echo "$release" | jq -r '[.assets[] | select(.name == "rpi-bootstrap.img")] | first | .url')

    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        warn "No rpi-bootstrap.img asset in bootstrap-latest release."
        return
    fi

    log "Downloading rpi-bootstrap.img..."
    download_asset "$asset_url" "$IMAGES_ROOT/bootstrap/rpi-bootstrap.img.tmp" || {
        warn "Download failed."
        rm -f "$IMAGES_ROOT/bootstrap/rpi-bootstrap.img.tmp"
        return
    }

    mv "$IMAGES_ROOT/bootstrap/rpi-bootstrap.img.tmp" "$IMAGES_ROOT/bootstrap/rpi-bootstrap.img"
    echo "$remote_id" > "$marker"
    log "Bootstrap IMG updated."
}

# ── Main loop ─────────────────────────────────────────────────────────────────
log "Starting Hyperion image poller"
log "  Repo:     $GITHUB_REPO"
log "  Interval: ${POLL_INTERVAL}s"
log "  Auth:     $([ -n "${GITHUB_TOKEN:-}" ] && echo "token set" || echo "anonymous (public repo only)")"

while true; do
    check_node      || warn "Node check failed unexpectedly."
    check_bootstrap || warn "Bootstrap check failed unexpectedly."
    log "Sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done
