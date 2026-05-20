#!/usr/bin/env bash
# Heimdall — workstation-side deploy script
#
# Runs ON THE WORKSTATION (where the age private key lives). Performs the full
# Phase 2 deploy sequence:
#   1. Decrypt env.sops.env and ship cleartext to Heimdall via SSH.
#   2. Decrypt technitium-admin-pw.sops and ship to Heimdall.
#   3. SSH to Heimdall and run `git pull` + `docker compose pull` + `docker compose up -d`.
#
# Idempotent. Safe to re-run after editing secrets or compose.yml.
#
# Heimdall never holds the age key. Cleartext secrets land at:
#   /opt/Homelab/Heimdall/.env
#   /opt/Homelab/Heimdall/secrets/technitium-admin-pw
# Both are .gitignore'd and chmod 600.
#
# Flags:
#   --no-secrets   Skip the SOPS-decrypt-and-ship steps. Use when only compose
#                  or repo content has changed.
#   --no-deploy    Ship secrets only; don't pull/up the stack.
#   --host <user@ip>  Override default heimdall target (default: owner@192.168.10.4).
#   --dry-run      Print the commands that would run, don't execute.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEIMDALL_HOST="${HEIMDALL_HOST:-owner@192.168.10.4}"
ENV_SOPS="${REPO_ROOT}/Heimdall/secrets/env.sops.env"
PW_SOPS="${REPO_ROOT}/Heimdall/secrets/technitium-admin-pw.sops"
ENV_REMOTE="/opt/Homelab/Heimdall/.env"
PW_REMOTE="/opt/Homelab/Heimdall/secrets/technitium-admin-pw"

DO_SECRETS=1
DO_DEPLOY=1
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-secrets) DO_SECRETS=0; shift ;;
        --no-deploy)  DO_DEPLOY=0; shift ;;
        --host)       HEIMDALL_HOST="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if [ -n "$DRY_RUN" ]; then
        printf '\033[1;36m[dry-run]\033[0m %s\n' "$*"
    else
        "$@"
    fi
}

# ─── Prerequisites ───────────────────────────────────────────────────────────────────
[ "$DO_SECRETS" -eq 1 ] && {
    command -v sops >/dev/null || die "sops not found. Install from github.com/getsops/sops/releases"
    [ -f "$ENV_SOPS" ] || die "Encrypted env file not found at $ENV_SOPS. Run generate-secrets.sh first."
    [ -f "$PW_SOPS" ]  || die "Encrypted password file not found at $PW_SOPS. Run generate-secrets.sh first."
}
command -v ssh >/dev/null || die "ssh not found"

log "Target: $HEIMDALL_HOST"

# ─── Secrets: decrypt on workstation, pipe to Heimdall ──────────────────────────────
if [ "$DO_SECRETS" -eq 1 ]; then
    log "Shipping .env (decrypted from $ENV_SOPS)..."
    if [ -n "$DRY_RUN" ]; then
        printf '\033[1;36m[dry-run]\033[0m sops --decrypt %s | ssh %s "tee %s > /dev/null && chmod 600 %s"\n' \
            "$ENV_SOPS" "$HEIMDALL_HOST" "$ENV_REMOTE" "$ENV_REMOTE"
    else
        sops --decrypt "$ENV_SOPS" | \
            ssh "$HEIMDALL_HOST" "tee $ENV_REMOTE > /dev/null && chmod 600 $ENV_REMOTE" \
            || die "Failed to ship .env"
    fi

    log "Shipping technitium-admin-pw (decrypted from $PW_SOPS)..."
    if [ -n "$DRY_RUN" ]; then
        printf '\033[1;36m[dry-run]\033[0m sops --decrypt --input-type binary --output-type binary %s | ssh %s "tee %s > /dev/null && chmod 600 %s"\n' \
            "$PW_SOPS" "$HEIMDALL_HOST" "$PW_REMOTE" "$PW_REMOTE"
    else
        sops --decrypt --input-type binary --output-type binary "$PW_SOPS" | \
            ssh "$HEIMDALL_HOST" "tee $PW_REMOTE > /dev/null && chmod 600 $PW_REMOTE" \
            || die "Failed to ship technitium-admin-pw"
    fi
else
    log "Skipping secrets shipment (--no-secrets)"
fi

# ─── Deploy: git pull + compose pull + compose up -d ────────────────────────────────
if [ "$DO_DEPLOY" -eq 1 ]; then
    # Preflight: docker group membership. If owner isn't in the docker group on
    # Heimdall, `docker compose` will fail with "permission denied while trying
    # to connect to the docker API at unix:///var/run/docker.sock". Fix once,
    # idempotent. setup.sh handles this on fresh installs; this guard catches
    # hosts that were set up before that fix landed.
    REMOTE_USER="${HEIMDALL_HOST%@*}"
    if ! ssh "$HEIMDALL_HOST" "getent group docker | grep -qw $REMOTE_USER" 2>/dev/null; then
        log "$REMOTE_USER not in docker group on $HEIMDALL_HOST; adding (sudo + tty)..."
        if [ -n "$DRY_RUN" ]; then
            printf '\033[1;36m[dry-run]\033[0m ssh -t %s "sudo usermod -aG docker %s"\n' "$HEIMDALL_HOST" "$REMOTE_USER"
        else
            ssh -t "$HEIMDALL_HOST" "sudo usermod -aG docker $REMOTE_USER" \
                || die "Failed to add $REMOTE_USER to docker group"
            log "Group membership added. (Takes effect on next SSH session, which is the one below.)"
        fi
    fi

    log "Running git pull + docker compose pull + up -d + onboard + seed on Heimdall..."
    REMOTE_CMD='set -e
        cd /opt/Homelab && git pull
        cd /opt/Homelab/Heimdall
        docker compose pull
        docker compose up -d

        # File-bind-mounts (Caddyfile, periphery configs, etc.) hold the old inode
        # across a git-pull that renames files. Restart containers whose bind-
        # mounted config files just changed so they pick up the new content.
        # `docker compose up -d` does NOT recreate or restart these — it only
        # acts on image / service-spec changes.
        if git -C /opt/Homelab diff HEAD@{1} HEAD --name-only 2>/dev/null | grep -qE "^Heimdall/caddy/Caddyfile$"; then
            echo "[remote] Caddyfile changed in this pull — restarting caddy..."
            docker compose restart caddy
        fi

        docker compose ps

        echo "[remote] Waiting for Komodo Core HTTP API on :9120..."
        for i in $(seq 1 30); do
            if curl -fsS -o /dev/null http://127.0.0.1:9120 2>/dev/null; then
                echo "[remote] Komodo Core reachable after ${i}s"
                break
            fi
            sleep 2
        done

        echo "[remote] Onboarding Periphery..."
        bash /opt/Homelab/Heimdall/scripts/onboard-periphery.sh

        echo "[remote] Waiting for Technitium API on :5380..."
        for i in $(seq 1 30); do
            if curl -fsS -o /dev/null http://127.0.0.1:5380 2>/dev/null; then
                echo "[remote] Technitium reachable after ${i}s"
                break
            fi
            sleep 2
        done

        echo "[remote] Seeding Technitium zone..."
        bash /opt/Homelab/Heimdall/scripts/seed-zones.sh

        echo "[remote] Reconciling Technitium blocklist subscriptions..."
        bash /opt/Homelab/Heimdall/scripts/seed-blocklists.sh'
    if [ -n "$DRY_RUN" ]; then
        printf '\033[1;36m[dry-run]\033[0m ssh %s "%s"\n' "$HEIMDALL_HOST" "$REMOTE_CMD"
    else
        ssh -t "$HEIMDALL_HOST" "$REMOTE_CMD" || die "Deploy failed on Heimdall"
    fi
else
    log "Skipping deploy (--no-deploy)"
fi

log "Done."
