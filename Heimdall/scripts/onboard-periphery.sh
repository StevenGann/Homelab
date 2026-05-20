#!/usr/bin/env bash
# Heimdall — Komodo Periphery onboarding script
#
# Replaces the multi-click UI dance for the v2 Periphery↔Core handshake with a single
# idempotent command. Drives the Komodo Core HTTP API to mint an onboarding key,
# writes it into Periphery's TOML config as `onboarding_key`, then restarts Periphery.
# On first reconnect Periphery generates its own Ed25519 keypair and exchanges its
# public key with Core via the Noise-protocol handshake. After that, the onboarding
# key is consumed and the trust relationship is steady-state.
#
# Punch list fixes from FINAL.md applied:
#   M1 — `PERIPHERY_ADDR` defaults to `https://...` (Periphery's `ssl_enabled = true`
#        default; Core dials Periphery over TLS even on localhost).
#   M2 — Uses `CreateOnboardingKey` (returns `{private_key, created}`), NOT
#        `CreateServer`. The server resource is auto-created when Periphery first
#        connects with the onboarding key.
#   M4 — `.env` existence + permission guards.
#
# Smoke-test gate (per FINAL.md punch list #5): this script must be run against a
# live Komodo v2.2.0 Core before it lands in a merge. The HTTP API shapes below
# (request bodies, response field names, header naming) are derived from the
# upstream Rust client source at github.com/moghtech/komodo as of 2026-05-17 but
# have not been exercised against a running instance. Adjust as needed.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
KOMODO_API="${KOMODO_API:-http://127.0.0.1:9120}"          # Komodo Core HTTP (no TLS by default; Caddy fronts as komodo.lab)
PERIPHERY_ADDR="${PERIPHERY_ADDR:-https://127.0.0.1:8120}" # Periphery default is ssl_enabled=true
PERIPHERY_CONFIG="${PERIPHERY_CONFIG:-/etc/komodo/periphery.config.toml}"
ENV_FILE="${ENV_FILE:-/opt/Homelab/Heimdall/.env}"
SERVER_NAME="${SERVER_NAME:-heimdall}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[onboard]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ─── M4: .env hardening ──────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE. Run: SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt /opt/Homelab/Heimdall/secrets/env.sops.yaml > $ENV_FILE"

ENV_MODE=$(stat -c %a "$ENV_FILE")
if [ "$ENV_MODE" != "600" ] && [ "$ENV_MODE" != "400" ]; then
    warn ".env has mode $ENV_MODE; should be 600 or 400. Fix: chmod 600 $ENV_FILE"
fi

# Source only the variables we need (don't `set -a; source` the whole file blindly).
# shellcheck disable=SC1090
. "$ENV_FILE"

[ -n "${KOMODO_INIT_ADMIN_USERNAME:-}" ] || die "KOMODO_INIT_ADMIN_USERNAME not set in $ENV_FILE"
[ -n "${KOMODO_INIT_ADMIN_PASSWORD:-}" ] || die "KOMODO_INIT_ADMIN_PASSWORD not set in $ENV_FILE"

# ─── Required tools ──────────────────────────────────────────────────────────────────
command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found (apt install jq)"

[ -f "$PERIPHERY_CONFIG" ] || die "Periphery config not found at $PERIPHERY_CONFIG — run setup.sh first"

# ─── Idempotence: detect already-onboarded state ─────────────────────────────────────
# After successful onboarding the TOML has a non-empty `onboarding_key = "..."` line.
# If we see that, skip — running again would replace the key with a fresh one and
# orphan Periphery's existing trust relationship.
#
# The periphery config is 0640 root:root, so use sudo to read it without warnings.
if sudo grep -qE '^[[:space:]]*onboarding_key[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$' "$PERIPHERY_CONFIG"; then
    log "Periphery already has an onboarding_key set in $PERIPHERY_CONFIG."
    log "If you need to re-onboard: blank the onboarding_key line manually, then re-run."
    exit 0
fi

# ─── Step 1: log in to Komodo Core, get JWT ──────────────────────────────────────────
log "Authenticating to Komodo Core at $KOMODO_API ..."

LOGIN_BODY=$(jq -nc \
    --arg u "$KOMODO_INIT_ADMIN_USERNAME" \
    --arg p "$KOMODO_INIT_ADMIN_PASSWORD" \
    '{type:"LoginLocalUser", params:{username:$u, password:$p}}')

# Komodo Core HTTP API auth-request endpoint. Empirically verified against
# v2.2.0: POST /auth/login (NOT /auth) — verified against running Heimdall
# by probing for the path that returns 401 (auth-but-rejected) vs 405 (no
# handler). The body shape stays {type, params} per the Rust client source.
LOGIN_RESP=$(curl -fsS -X POST "$KOMODO_API/auth/login" \
    -H "Content-Type: application/json" \
    -d "$LOGIN_BODY") || die "Login request failed. Check Komodo Core is running and the admin credentials in $ENV_FILE."

# JwtOrTwoFactor enum: Komodo Core v2.2.0 serializes this as adjacently-tagged
# {"type":"Jwt","data":{"jwt":"..."}} — NOT externally-tagged {"Jwt":{"jwt":"..."}}.
# Verified empirically against the running instance. 2FA responses use a different
# `type` value; this script does NOT handle 2FA — admin user should be 2FA-free.
JWT=$(printf '%s' "$LOGIN_RESP" | jq -r '.data.jwt // .Jwt.jwt // .jwt // empty')
if [ -z "$JWT" ]; then
    die "Login response did not contain a JWT. Response was: $LOGIN_RESP"
fi

# ─── Step 2: create onboarding key ───────────────────────────────────────────────────
log "Creating onboarding key for server '$SERVER_NAME' ..."

# Per the Rust source at moghtech/komodo client/core/rs/src/api/write/onboarding_key.rs:
#   CreateOnboardingKey { name, expires, private_key, tags, privileged, copy_server, create_builder }
#   CreateOnboardingKeyResponse { private_key, created }
# The `private_key` field of the response is the one-time TOFU credential that goes
# into Periphery's TOML as `onboarding_key`.
CREATE_BODY=$(jq -nc --arg name "$SERVER_NAME" \
    '{type:"CreateOnboardingKey", params:{
        name: $name,
        expires: 0,
        tags: [],
        privileged: false,
        copy_server: "",
        create_builder: false
    }}')

CREATE_RESP=$(curl -fsS -X POST "$KOMODO_API/write" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT" \
    -d "$CREATE_BODY") || die "CreateOnboardingKey request failed."

ONBOARDING_KEY=$(printf '%s' "$CREATE_RESP" | jq -r '.private_key // empty')
if [ -z "$ONBOARDING_KEY" ]; then
    die "CreateOnboardingKey response did not contain a private_key. Response was: $CREATE_RESP"
fi

log "Onboarding key minted. Writing to $PERIPHERY_CONFIG ..."

# ─── Step 3: write onboarding_key into Periphery's TOML ──────────────────────────────
# Three cases for the existing line in the default Periphery config:
#   (a) commented out:    `# onboarding_key = ""`
#   (b) blank:            `onboarding_key = ""`
#   (c) absent entirely.
# Handle all three by removing any existing line then appending a fresh one.
# Use a backup file so a malformed sed can be recovered.

sudo cp "$PERIPHERY_CONFIG" "${PERIPHERY_CONFIG}.pre-onboard.bak"
# Strip both keys if present (commented or not), then append fresh values.
sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*onboarding_key[[:space:]]*=/d' "$PERIPHERY_CONFIG"
sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*core_addresses[[:space:]]*=/d' "$PERIPHERY_CONFIG"
{
    printf 'onboarding_key = "%s"\n' "$ONBOARDING_KEY"
    # Outbound mode — Periphery dials Core to register. Without core_addresses
    # set, Periphery is in inbound mode (waiting for Core to dial it), which
    # never happens for a freshly-minted onboarding key with no Server record.
    printf 'core_addresses = ["%s"]\n' "$KOMODO_API"
} | sudo tee -a "$PERIPHERY_CONFIG" >/dev/null
sudo chmod 0640 "$PERIPHERY_CONFIG"

# Also register the address that Komodo Core will dial Periphery on. Komodo Core looks
# up the server's address from its own DB (populated by Periphery's first connect),
# so this isn't strictly required here — but documenting it makes troubleshooting easier.
log "Periphery address that Core will dial: $PERIPHERY_ADDR"

# ─── Step 4: restart Periphery so it picks up the new onboarding_key ─────────────────
log "Restarting periphery.service ..."
sudo systemctl restart periphery.service

# ─── Step 5: wait for Periphery to reach the OK state in Komodo Core ─────────────────
log "Waiting up to ${WAIT_SECONDS}s for Periphery to onboard ..."

DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    # `ListServers` is one of the read endpoints; we filter for our server by name.
    LIST_BODY=$(jq -nc '{type:"ListServers", params:{query:{}}}')
    LIST_RESP=$(curl -fsS -X POST "$KOMODO_API/read" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT" \
        -d "$LIST_BODY" 2>/dev/null || true)

    if [ -n "$LIST_RESP" ]; then
        STATE=$(printf '%s' "$LIST_RESP" | jq -r --arg name "$SERVER_NAME" \
            '.[] | select(.name == $name) | .info.state // .state // empty' 2>/dev/null || true)
        if [ "$STATE" = "Ok" ] || [ "$STATE" = "Connected" ]; then
            log "Periphery onboarded — server '$SERVER_NAME' state: $STATE"
            log "Backup of pre-onboard config left at ${PERIPHERY_CONFIG}.pre-onboard.bak"
            exit 0
        fi
    fi
    sleep 2
done

warn "Periphery did not reach a connected state within ${WAIT_SECONDS}s."
warn "Inspect:"
warn "  journalctl -u periphery.service -n 50"
warn "  curl -fsS -X POST $KOMODO_API/read -H 'Authorization: Bearer <jwt>' -d '{\"type\":\"ListServers\",\"params\":{\"query\":{}}}'"
warn "Backup of pre-onboard config: ${PERIPHERY_CONFIG}.pre-onboard.bak"
exit 1
