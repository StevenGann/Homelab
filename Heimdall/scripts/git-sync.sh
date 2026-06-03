#!/usr/bin/env bash
# Heimdall — GitOps clone refresh. Keeps /opt/Homelab matching origin/main.
#
# Run by heimdall-git-sync.timer (every few minutes) AND usable by hand. Uses
# `fetch + reset --hard` (fresh-clone semantics) so it's robust against the local
# divergence / root-owned-file drift that made a plain `git pull` unreliable here.
#
# IMPORTANT scope: this syncs FILES ONLY. It does NOT restart containers or ship
# secrets — Heimdall never holds the SOPS age key, so deploys stay workstation-
# driven (scripts/deploy.sh). A push therefore lands on disk within a few minutes;
# config that's read live (e.g. Caddyfile on reload) applies on the next deploy.
#
# `reset --hard` discards any uncommitted local edits under /opt/Homelab — that's
# the GitOps contract (the host matches git). Untracked files are left alone.
set -euo pipefail

REPO="${REPO:-/opt/Homelab}"
BRANCH="${BRANCH:-main}"
OWNER="${OWNER:-owner}"

# This unit runs as root but the repo is owned by $OWNER; git ≥2.35 refuses that
# ("dubious ownership") without an explicit exception. Scope it to this repo for
# all git calls below (no persistent global config).
export GIT_CONFIG_PARAMETERS="'safe.directory=${REPO}'"

cd "$REPO" || { echo "git-sync: $REPO not found"; exit 1; }

git fetch origin -q "$BRANCH"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/${BRANCH}")

if [ "$LOCAL" = "$REMOTE" ]; then
    exit 0   # already current — stay quiet (timer runs often)
fi

echo "git-sync: ${LOCAL:0:8} -> ${REMOTE:0:8} ($(git log --oneline -1 "origin/${BRANCH}"))"

# Capture the tracked files this sync will touch, BEFORE the reset.
mapfile -t CHANGED < <(git diff --name-only "$LOCAL" "origin/${BRANCH}")

git reset --hard "origin/${BRANCH}"

# Restore owner ownership — but ONLY on .git and the tracked files we just changed.
# NEVER chown -R the whole repo: it also holds live container data with
# container-managed ownership (komodo-data/mongo, technitium/, caddy/data,
# k3s-control-plane/server) — a blanket chown would break those services.
if id "$OWNER" >/dev/null 2>&1; then
    chown -R "$OWNER:$OWNER" "$REPO/.git" 2>/dev/null || true
    for f in "${CHANGED[@]}"; do
        [ -e "$REPO/$f" ] && chown "$OWNER:$OWNER" "$REPO/$f" 2>/dev/null || true
    done
fi
echo "git-sync: now at $(git rev-parse --short HEAD)"
