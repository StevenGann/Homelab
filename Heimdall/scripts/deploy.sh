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
K3S_ENV_SOPS="${REPO_ROOT}/Heimdall/secrets/k3s-control-plane.sops.env"
CF_CREDS_SOPS="${REPO_ROOT}/Heimdall/secrets/cloudflared-credentials.sops"
DDNS_SOPS="${REPO_ROOT}/Heimdall/secrets/ddns-config.json.sops"
DDNS_REMOTE="/opt/Homelab/Heimdall/ddns-updater/data/config.json"
ENV_REMOTE="/opt/Homelab/Heimdall/.env"
PW_REMOTE="/opt/Homelab/Heimdall/secrets/technitium-admin-pw"
K3S_ENV_REMOTE="/opt/Homelab/Heimdall/k3s-control-plane/.env"
CF_CREDS_REMOTE="/opt/Homelab/Heimdall/cloudflared/credentials.json"

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

    log "Shipping ddns-updater config (decrypted from $DDNS_SOPS)..."
    if [ -n "$DRY_RUN" ]; then
        printf '\033[1;36m[dry-run]\033[0m sops --decrypt --input-type binary --output-type binary %s | ssh %s "install -d $(dirname %s) && tee %s > /dev/null && chmod 600 %s"\n' \
            "$DDNS_SOPS" "$HEIMDALL_HOST" "$DDNS_REMOTE" "$DDNS_REMOTE" "$DDNS_REMOTE"
    else
        sops --decrypt --input-type binary --output-type binary "$DDNS_SOPS" | \
            ssh "$HEIMDALL_HOST" "install -d \"$(dirname "$DDNS_REMOTE")\" && tee $DDNS_REMOTE > /dev/null && chmod 600 $DDNS_REMOTE" \
            || die "Failed to ship ddns-updater config"
    fi

    # k3s control plane env — present only after the operator has minted the
    # join token (see Heimdall/k3s-control-plane/README.md §"Initial mint").
    # Tolerate absence so the rest of the deploy still works during bring-up.
    if [ -f "$K3S_ENV_SOPS" ]; then
        log "Shipping k3s-control-plane .env (decrypted from $K3S_ENV_SOPS)..."
        if [ -n "$DRY_RUN" ]; then
            printf '\033[1;36m[dry-run]\033[0m sops --decrypt --input-type dotenv --output-type dotenv %s | ssh %s "sudo install -d -m 0755 $(dirname %s) && sudo tee %s > /dev/null && sudo chmod 600 %s"\n' \
                "$K3S_ENV_SOPS" "$HEIMDALL_HOST" "$K3S_ENV_REMOTE" "$K3S_ENV_REMOTE" "$K3S_ENV_REMOTE"
        else
            K3S_DIR="$(dirname "$K3S_ENV_REMOTE")"
            sops --decrypt --input-type dotenv --output-type dotenv "$K3S_ENV_SOPS" | \
                ssh "$HEIMDALL_HOST" "sudo install -d -m 0755 $K3S_DIR && sudo tee $K3S_ENV_REMOTE > /dev/null && sudo chmod 600 $K3S_ENV_REMOTE" \
                || die "Failed to ship k3s-control-plane .env"
        fi
    else
        warn "k3s-control-plane.sops.env not found — skipping (mint it first per Heimdall/k3s-control-plane/README.md)."
    fi

    # cloudflared tunnel credentials — present only after the operator has run
    # `cloudflared tunnel create` and SOPS-encrypted the JSON (see
    # Heimdall/cloudflared/README.md). Tolerate absence during bring-up.
    if [ -f "$CF_CREDS_SOPS" ]; then
        log "Shipping cloudflared credentials (decrypted from $CF_CREDS_SOPS)..."
        if [ -n "$DRY_RUN" ]; then
            printf '\033[1;36m[dry-run]\033[0m sops --decrypt --input-type json --output-type json %s | ssh %s "sudo install -d -m 0755 $(dirname %s) && sudo tee %s > /dev/null && sudo chmod 600 %s"\n' \
                "$CF_CREDS_SOPS" "$HEIMDALL_HOST" "$CF_CREDS_REMOTE" "$CF_CREDS_REMOTE" "$CF_CREDS_REMOTE"
        else
            CF_DIR="$(dirname "$CF_CREDS_REMOTE")"
            sops --decrypt --input-type json --output-type json "$CF_CREDS_SOPS" | \
                ssh "$HEIMDALL_HOST" "sudo install -d -m 0755 $CF_DIR && sudo tee $CF_CREDS_REMOTE > /dev/null && sudo chmod 600 $CF_CREDS_REMOTE" \
                || die "Failed to ship cloudflared credentials"
        fi
    else
        warn "cloudflared-credentials.sops not found — skipping tunnel (create it first per Heimdall/cloudflared/README.md)."
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
        # Sync the clone via the shared GitOps script (runs as root, surgical
        # chown — never blanket-chowns the live container data under the repo).
        # Same logic the heimdall-git-sync.timer runs; robust vs the divergence
        # that broke a plain `git pull`. Falls through if the script predates this.
        if [ -f /opt/Homelab/Heimdall/scripts/git-sync.sh ]; then
            sudo bash /opt/Homelab/Heimdall/scripts/git-sync.sh
        else
            cd /opt/Homelab && git fetch origin -q main && git reset --hard origin/main
        fi
        cd /opt/Homelab/Heimdall
        docker compose pull
        docker compose up -d

        # Static web assets tracked in git (caddy/www/) → the served dir
        # (caddy/data is gitignored runtime state). alfred.lab serves
        # /data/alfred.html via the Caddyfile.
        if [ -d /opt/Homelab/Heimdall/caddy/www ]; then
            cp -f /opt/Homelab/Heimdall/caddy/www/*.html \
                  /opt/Homelab/Heimdall/caddy/data/ 2>/dev/null || true
        fi

        # File-bind-mounts (Caddyfile, periphery configs, etc.) hold the old inode
        # across a git-pull that renames files. Restart containers whose bind-
        # mounted config files just changed so they pick up the new content.
        # `docker compose up -d` does NOT recreate or restart these — it only
        # acts on image / service-spec changes.
        if git -C /opt/Homelab diff HEAD@{1} HEAD --name-only 2>/dev/null | grep -qE "^Heimdall/caddy/Caddyfile$"; then
            echo "[remote] Caddyfile changed in this pull — restarting caddy..."
            docker compose restart caddy
        fi

        # ─── Hyperion flashing stack (separate Compose project) ─────────────
        # Lives under /opt/Homelab/Heimdall/hyperion/. Per the dev-hyperion-
        # flashing-to-heimdall pipeline FINAL.md Tier 1.2, ALL state lives
        # under a single root so future re-migration is `rsync one root +
        # change one IP + redeploy`. Do not add bind-mounts that escape this
        # root.
        echo "[remote] Bringing up Hyperion flashing stack..."
        sudo install -d -o root -g root -m 0755 \
            /opt/Homelab/Heimdall/hyperion/images \
            /opt/Homelab/Heimdall/hyperion/journal
        cd /opt/Homelab/Heimdall/hyperion
        docker compose pull
        docker compose up -d
        if git -C /opt/Homelab diff HEAD@{1} HEAD --name-only 2>/dev/null | grep -qE "^Heimdall/hyperion/nginx\.conf$"; then
            echo "[remote] hyperion/nginx.conf changed in this pull — restarting nginx..."
            docker compose restart nginx
        fi
        docker compose ps

        # ─── k3s control plane (separate Compose project) ────────────────
        # Lives under /opt/Homelab/Heimdall/k3s-control-plane/. Same
        # single-root portability rule as the hyperion stack. Skip if the
        # .env was not shipped (token not yet minted).
        if [ -f /opt/Homelab/Heimdall/k3s-control-plane/.env ]; then
            echo "[remote] Bringing up k3s control plane..."
            sudo install -d -o root -g root -m 0755 \
                /opt/Homelab/Heimdall/k3s-control-plane/server \
                /opt/Homelab/Heimdall/k3s-control-plane/kubeconfig
            cd /opt/Homelab/Heimdall/k3s-control-plane
            docker compose pull
            docker compose up -d
            docker compose ps
        else
            echo "[remote] k3s control plane .env not present — skipping (mint the token first)."
        fi

        # ─── Authentik (SSO) — separate Compose project ──────────────────
        # Same single-root portability rule. Substitution vars come from the
        # shipped .env via --env-file. media/certs/custom-templates are chowned
        # to uid 1000 (the authentik runtime user); postgres/redis self-chown.
        echo "[remote] Bringing up Authentik (SSO)..."
        sudo install -d -o root -g root -m 0755 \
            /opt/Homelab/Heimdall/authentik/database \
            /opt/Homelab/Heimdall/authentik/redis
        sudo install -d -o 1000 -g 1000 -m 0755 \
            /opt/Homelab/Heimdall/authentik/media \
            /opt/Homelab/Heimdall/authentik/certs \
            /opt/Homelab/Heimdall/authentik/custom-templates
        cd /opt/Homelab/Heimdall/authentik
        docker compose --env-file /opt/Homelab/Heimdall/.env pull
        docker compose --env-file /opt/Homelab/Heimdall/.env up -d
        docker compose --env-file /opt/Homelab/Heimdall/.env ps

        # ─── Cloudflare Tunnel — separate Compose project ────────────────
        # Public web access. Skips until credentials.json is shipped (operator
        # runs `cloudflared tunnel create` first — see Heimdall/cloudflared/).
        if [ -f /opt/Homelab/Heimdall/cloudflared/credentials.json ]; then
            echo "[remote] Bringing up Cloudflare Tunnel..."
            cd /opt/Homelab/Heimdall/cloudflared
            docker compose pull
            docker compose up -d
            docker compose ps
        else
            echo "[remote] cloudflared credentials.json not present — skipping tunnel (create it first)."
        fi

        cd /opt/Homelab/Heimdall

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
