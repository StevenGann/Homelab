#!/usr/bin/env bash
# Thoth — workstation-side deploy. Mirrors Heimdall/scripts/deploy.sh.
#
# Decrypts Thoth/secrets/env.sops.env on the workstation (where the age key lives)
# and ships the cleartext to /opt/Homelab/Thoth/.env (mode 600) over SSH, ships the
# compose file, then `docker compose up -d` on Thoth. Thoth never holds the age key.
#
# Flags: --no-secrets (skip env ship), --no-deploy (ship only), --host <user@ip>.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
THOTH_HOST="${THOTH_HOST:-owner@192.168.10.144}"
ENV_SOPS="${REPO_ROOT}/Thoth/secrets/env.sops.env"
ENV_REMOTE="/opt/Homelab/Thoth/.env"
COMPOSE="${REPO_ROOT}/Thoth/docker-compose.yml"
COMPOSE_REMOTE="/opt/Homelab/Thoth/docker-compose.yml"

DO_SECRETS=1; DO_DEPLOY=1
while [ $# -gt 0 ]; do case "$1" in
    --no-secrets) DO_SECRETS=0; shift ;;
    --no-deploy)  DO_DEPLOY=0; shift ;;
    --host)       THOTH_HOST="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
esac; done

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || die "ssh not found"
ssh "$THOTH_HOST" 'install -d -m 0755 /opt/Homelab/Thoth /opt/Homelab/Thoth/periphery'

if [ "$DO_SECRETS" -eq 1 ]; then
    command -v sops >/dev/null || die "sops not found"
    [ -f "$ENV_SOPS" ] || die "missing $ENV_SOPS"
    log "Shipping .env (decrypted)..."
    sops --decrypt "$ENV_SOPS" | ssh "$THOTH_HOST" "tee $ENV_REMOTE >/dev/null && chmod 600 $ENV_REMOTE" \
        || die "failed to ship .env"
fi

log "Shipping compose..."
scp -q "$COMPOSE" "$THOTH_HOST:$COMPOSE_REMOTE"

if [ "$DO_DEPLOY" -eq 1 ]; then
    log "docker compose pull + up -d on $THOTH_HOST..."
    ssh "$THOTH_HOST" 'cd /opt/Homelab/Thoth && docker compose pull && docker compose up -d && docker compose ps'
fi
log "Done."
