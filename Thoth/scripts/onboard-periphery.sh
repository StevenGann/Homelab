#!/usr/bin/env bash
# Thoth — onboard the Periphery CONTAINER into Komodo Core (on Heimdall).
#
# Adapts Heimdall/scripts/onboard-periphery.sh for a REMOTE periphery: mint the
# onboarding key on Heimdall (Core API at 127.0.0.1:9120, admin creds from
# Heimdall's .env), then write it into Thoth's periphery config + restart.
#
# Periphery + Core MUST be the same version (komodo-periphery:2.2.0 == komodo-core:2.2.0).
#
# Run from the workstation. Idempotent-ish: re-running mints a fresh key.
set -euo pipefail
HEIMDALL="${HEIMDALL:-owner@192.168.10.4}"
THOTH="${THOTH:-owner@192.168.10.144}"
SERVER_NAME="${SERVER_NAME:-thoth}"
# Core address THIS periphery dials to register. Core is bound to 127.0.0.1:9120 on
# Heimdall and fronted by Caddy as komodo.lab — reachable from Thoth over the LAN.
CORE_ADDR="${CORE_ADDR:-https://komodo.lab}"
PERIPHERY_TOML="/opt/Homelab/Thoth/periphery/periphery.config.toml"
log(){ printf '\033[1;34m[onboard]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. mint an onboarding key from Komodo Core (on Heimdall) ──────────────────
log "Minting onboarding key from Komodo Core for '$SERVER_NAME'..."
KEY=$(ssh "$HEIMDALL" 'bash -s' <<'REMOTE'
set -euo pipefail
. /opt/Homelab/Heimdall/.env
API=http://127.0.0.1:9120
JWT=$(curl -fsS -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$KOMODO_INIT_ADMIN_USERNAME" --arg p "$KOMODO_INIT_ADMIN_PASSWORD" \
        '{type:"LoginLocalUser",params:{username:$u,password:$p}}')" \
  | jq -r '.data.jwt // .jwt // empty')
[ -n "$JWT" ] || { echo "LOGIN_FAILED" >&2; exit 1; }
curl -fsS -X POST "$API/write" -H 'Content-Type: application/json' -H "Authorization: Bearer $JWT" \
  -d "$(jq -nc --arg n thoth '{type:"CreateOnboardingKey",params:{name:$n,expires:0,tags:[],privileged:false,copy_server:"",create_builder:false}}')" \
  | jq -r '.private_key // empty'
REMOTE
) || die "Failed to mint onboarding key (check Komodo Core + admin creds)."
[ -n "$KEY" ] || die "Empty onboarding key returned."
log "Onboarding key minted."

# ── 2. write the key into Thoth's periphery config + restart the container ────
log "Writing onboarding_key + core_addresses into $PERIPHERY_TOML on Thoth..."
ssh "$THOTH" "sudo bash -c 'cat > $PERIPHERY_TOML' <<EOF
onboarding_key = \"$KEY\"
core_addresses = [\"$CORE_ADDR\"]
EOF
cd /opt/Homelab/Thoth && docker compose restart periphery"
log "Periphery restarted. Verify in komodo.lab → Servers (server '$SERVER_NAME' should appear/connect)."
log "If it stays disconnected, the likely cause is TLS trust on $CORE_ADDR (internal CA) —"
log "set CORE_ADDR to a CA-trusted/IP address, or add the server in the UI."
