#!/usr/bin/env bash
# Heimdall — nightly backup script
#
# Snapshots Heimdall's backup-critical bind-mount paths to Akasha via rsync.
# Installed as a daily cron via setup.sh (TODO: cron wiring belongs in setup.sh
# alongside the other host setup; this script is the standalone primitive).
#
# Punch list M7 fix: replaces the iter-1 "operator wires this up" placeholder
# with a committed script that handles DATE rotation and 30-day retention.
#
# Idempotent. Safe to run manually for ad-hoc snapshots.
#
# Operator invocation:
#   sudo bash Heimdall/scripts/backup.sh                 # snapshot to today's DATE dir
#   sudo bash Heimdall/scripts/backup.sh --prune-only    # just delete old snapshots, no copy
#   sudo bash Heimdall/scripts/backup.sh --dry-run       # show what would be done

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
HEIMDALL_DIR="${HEIMDALL_DIR:-/opt/Homelab/Heimdall}"
REMOTE="${REMOTE:-owner@192.168.10.247}"
REMOTE_BASE="${REMOTE_BASE:-/mnt/Media-Storage/Infra-Storage/heimdall-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DATE_TAG="$(date -u +%Y-%m-%d)"

# Backup-critical paths (from FINAL.md §3.8 / approved plan §3.8)
BACKUP_PATHS=(
    "caddy/data"               # Internal-CA root + ACME store — losing this loses LAN trust
    "technitium/config"        # Technitium zones, blocklists, settings (binary dns.config)
    "komodo-data/mongo-data"   # Komodo audit log + Stack state + onboarding key state
    "komodo-data/keys"         # Komodo internal Ed25519 keys
)

DRY_RUN=""
PRUNE_ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN="--dry-run"; shift ;;
        --prune-only) PRUNE_ONLY=1; shift ;;
        *) printf 'Unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v rsync >/dev/null || die "rsync not found (apt install rsync)"

# ─── Copy phase ──────────────────────────────────────────────────────────────────────
if [ -z "$PRUNE_ONLY" ]; then
    REMOTE_DIR="${REMOTE_BASE}/${DATE_TAG}"
    log "Snapshot target: ${REMOTE}:${REMOTE_DIR}"
    log "Retention: ${RETENTION_DAYS} days"
    log "${#BACKUP_PATHS[@]} source path(s)"
    [ -n "$DRY_RUN" ] && log "DRY RUN — no data will be transferred"

    # Ensure remote parent directory exists. SSH command is bounded to the parent
    # so the script can't escape the configured base path.
    ssh "$REMOTE" "mkdir -p $(printf '%q' "$REMOTE_BASE")"

    for rel in "${BACKUP_PATHS[@]}"; do
        SRC="${HEIMDALL_DIR}/${rel}/"
        if [ ! -d "${SRC%/}" ]; then
            warn "Source missing: $SRC — skipping"
            continue
        fi

        DST_REL="${rel}"
        DST="${REMOTE_DIR}/${DST_REL}/"
        # shellcheck disable=SC2086
        rsync -a --delete --info=stats1 $DRY_RUN \
            --rsync-path="mkdir -p $(printf '%q' "${REMOTE_DIR}/$(dirname "$DST_REL")") && rsync" \
            "$SRC" "${REMOTE}:${DST}" \
            || warn "rsync of $rel returned non-zero; continuing with remaining paths"
    done

    log "Snapshot for ${DATE_TAG} complete."
fi

# ─── Prune phase ─────────────────────────────────────────────────────────────────────
log "Pruning snapshots older than ${RETENTION_DAYS} days from ${REMOTE}:${REMOTE_BASE} ..."

# Use find -maxdepth 1 -mtime to avoid following nested dirs. The pattern matches
# our DATE_TAG format (YYYY-MM-DD); other dirs in the base path are not touched.
REMOTE_PRUNE_CMD="find $(printf '%q' "$REMOTE_BASE") -maxdepth 1 -mindepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}$' -mtime +${RETENTION_DAYS}"

if [ -n "$DRY_RUN" ]; then
    log "DRY RUN — would delete:"
    ssh "$REMOTE" "$REMOTE_PRUNE_CMD" || true
else
    ssh "$REMOTE" "$REMOTE_PRUNE_CMD -exec rm -rf {} +" || warn "Prune returned non-zero"
fi

log "Done."
