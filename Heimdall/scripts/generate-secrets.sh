#!/usr/bin/env bash
# Heimdall — one-shot SOPS-encrypted secrets generator
#
# Run on the WORKSTATION (where ~/.config/sops/age/keys.txt lives), not on Heimdall.
# Produces two SOPS-encrypted files committed to the repo:
#
#   Heimdall/secrets/env.sops.env             — Komodo + Mongo env vars
#   Heimdall/secrets/technitium-admin-pw.sops — single-line Technitium admin password
#
# After committing + pushing, the operator deploys to Heimdall by decrypting on the
# workstation and shipping the cleartext over SSH (see end-of-script instructions).
#
# Idempotent: refuses to overwrite existing encrypted files. To rotate, delete the
# file(s) you want regenerated first, then re-run.

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/Heimdall/secrets"
ENV_FILE="${SECRETS_DIR}/env.sops.env"
TECH_PW_FILE="${SECRETS_DIR}/technitium-admin-pw.sops"
SOPS_CONFIG="${REPO_ROOT}/Heimdall/.sops.yaml"
AGE_KEY_FILE="${AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[gen-secrets]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Prerequisites ───────────────────────────────────────────────────────────────────
command -v sops    >/dev/null || die "sops not found. Install from github.com/getsops/sops/releases"
command -v openssl >/dev/null || die "openssl not found (apt install openssl)"

[ -f "$AGE_KEY_FILE" ]  || die "Age private key not found at $AGE_KEY_FILE. Set AGE_KEY_FILE env to override."
[ -f "$SOPS_CONFIG" ]   || die "SOPS config not found at $SOPS_CONFIG. This script must run from a Homelab checkout."

# Extract the age public key (recipient) from the key file. Pass it to sops
# via `--age` rather than relying on the creation_rules path-walk — sops walks
# up from the *input* file looking for .sops.yaml, and we write plaintext to
# /tmp/ (outside the repo), so the walk never reaches Heimdall/.sops.yaml.
AGE_RECIPIENT=$(grep -E '^# public key:' "$AGE_KEY_FILE" | awk '{print $4}')
[ -n "$AGE_RECIPIENT" ] || die "Could not extract age public key from $AGE_KEY_FILE (no '# public key:' line). Is this a valid age-keygen output file?"

# Sanity-check against the .sops.yaml recipient — they should match. If they don't,
# someone rotated the key without updating .sops.yaml (or vice versa), and decrypting
# anything we encrypt here will be impossible without the right private key.
CONFIG_RECIPIENT=$(grep -E '^\s*age:' "$SOPS_CONFIG" | awk '{print $2}' | head -1)
if [ -n "$CONFIG_RECIPIENT" ] && [ "$AGE_RECIPIENT" != "$CONFIG_RECIPIENT" ]; then
    warn "Mismatch: age key file has public key  $AGE_RECIPIENT"
    warn "          Heimdall/.sops.yaml expects $CONFIG_RECIPIENT"
    die  "Update Heimdall/.sops.yaml (and Hyperion/.sops.yaml) to match the private key, or vice versa, before generating secrets."
fi
log "Encrypting to recipient: $AGE_RECIPIENT"

# ─── Random-secret generators ────────────────────────────────────────────────────────
# 32-char base64-ish; strip the chars that need quoting in dotenv ('/' and '+' don't
# need quoting per se but they're noisier in logs; '=' makes truncation unreliable).
rand_pw() {
    local len=${1:-32}
    openssl rand -base64 48 | tr -d '/+=' | head -c "$len"
}

# 64-char hex (for JWT/webhook signing keys — fixed-length, no special chars).
rand_hex() {
    local len=${1:-64}
    openssl rand -hex $(( (len + 1) / 2 )) | head -c "$len"
}

# ─── Generate env.sops.env ───────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    warn "$ENV_FILE already exists; not overwriting. Delete it to rotate."
else
    log "Generating $ENV_FILE..."

    PLAINTEXT=$(mktemp)
    chmod 0600 "$PLAINTEXT"
    cat > "$PLAINTEXT" <<EOF
# Heimdall — Komodo + Mongo secrets
# Decrypt on the workstation; ship the cleartext to Heimdall via SSH.

KOMODO_DATABASE_USERNAME=komodo
KOMODO_DATABASE_PASSWORD=$(rand_pw 40)
KOMODO_INIT_ADMIN_USERNAME=owner
KOMODO_INIT_ADMIN_PASSWORD=$(rand_pw 32)
KOMODO_JWT_SECRET=$(rand_hex 64)
KOMODO_WEBHOOK_SECRET=$(rand_hex 32)
EOF

    # Pass --age explicitly. Path-based creation_rules don't help here because the
    # input is a /tmp/ file. The .env extension on the output path is informational
    # for humans; sops uses --input-type/--output-type to decide format.
    #
    # Write to a temp output and atomically rename on success — shell redirection
    # (`> "$ENV_FILE"`) truncates the target BEFORE sops runs, so a sops failure would
    # leave a 0-byte file that the idempotence guard above would then refuse to overwrite.
    ENC_TMP=$(mktemp)
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
        sops --encrypt --age "$AGE_RECIPIENT" --input-type dotenv --output-type dotenv "$PLAINTEXT" > "$ENC_TMP" || {
            rm -f "$PLAINTEXT" "$ENC_TMP"
            die "sops encrypt failed for env file"
        }
    mv "$ENC_TMP" "$ENV_FILE"
    rm -f "$PLAINTEXT"

    chmod 0644 "$ENV_FILE"
    log "Wrote $ENV_FILE."
fi

# ─── Generate technitium-admin-pw.sops ───────────────────────────────────────────────
if [ -f "$TECH_PW_FILE" ]; then
    warn "$TECH_PW_FILE already exists; not overwriting. Delete it to rotate."
else
    log "Generating $TECH_PW_FILE..."

    # Single-line password file. Bind-mounted into the Technitium container as
    # /run/secrets/technitium-admin-pw and consumed by DNS_SERVER_ADMIN_PASSWORD_FILE.
    PLAINTEXT=$(mktemp)
    chmod 0600 "$PLAINTEXT"
    printf '%s\n' "$(rand_pw 32)" > "$PLAINTEXT"

    # Pass --age explicitly (same reason as above — input is /tmp/, so creation_rules
    # path-walk doesn't apply). Binary mode preserves the file as a single base64 blob;
    # decrypt with `sops --decrypt --input-type binary --output-type binary`.
    # Atomic-write (see env.sops.env above for the rationale).
    ENC_TMP=$(mktemp)
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
        sops --encrypt --age "$AGE_RECIPIENT" --input-type binary --output-type binary "$PLAINTEXT" > "$ENC_TMP" || {
            rm -f "$PLAINTEXT" "$ENC_TMP"
            die "sops encrypt failed for technitium password file"
        }
    mv "$ENC_TMP" "$TECH_PW_FILE"
    rm -f "$PLAINTEXT"

    chmod 0644 "$TECH_PW_FILE"
    log "Wrote $TECH_PW_FILE."
fi

# ─── Next steps ──────────────────────────────────────────────────────────────────────
log
log "Done. Next steps:"
log
log "  1. Review the generated files (still encrypted; viewable but cleartext requires the age key):"
log "       sops --decrypt $ENV_FILE | head"
log
log "  2. Commit and push:"
log "       cd $REPO_ROOT"
log "       git add Heimdall/secrets/env.sops.env Heimdall/secrets/technitium-admin-pw.sops"
log "       git commit -m 'heimdall: scaffold encrypted secrets'"
log "       git push"
log
log "  3. On Heimdall, pull the new commit:"
log "       ssh owner@192.168.10.4 'cd /opt/Homelab && sudo git pull'"
log
log "  4. From the workstation, decrypt and ship to Heimdall:"
log "       sops --decrypt $ENV_FILE | \\"
log "           ssh owner@192.168.10.4 'sudo tee /opt/Homelab/Heimdall/.env > /dev/null && sudo chmod 600 /opt/Homelab/Heimdall/.env'"
log "       sops --decrypt --input-type binary --output-type binary $TECH_PW_FILE | \\"
log "           ssh owner@192.168.10.4 'sudo tee /opt/Homelab/Heimdall/secrets/technitium-admin-pw > /dev/null && sudo chmod 600 /opt/Homelab/Heimdall/secrets/technitium-admin-pw'"
log
log "  5. Then on Heimdall, bring up the stack:"
log "       cd /opt/Homelab/Heimdall && docker compose pull && docker compose up -d"
