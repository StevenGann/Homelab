#!/usr/bin/env bash
# register-node-key.sh
# Provision a Hyperion node's secrets for the nixos-anywhere remote-flash flow.
#
# Run once per node, before the first ./flash-node.sh. It:
#   1. Generates a per-node age keypair and an SSH host keypair.
#   2. Packs them into the exact on-target --extra-files layout and
#      age-encrypts the bundle to the OPERATOR's key as
#      nixos/node-keys/<hostname>.tar.age (safe to commit — only the operator
#      can decrypt it; this is the durable source of truth across re-flashes).
#   3. Appends the node's age PUBLIC key to .sops.yaml under the nixos/secrets
#      rule and runs `sops updatekeys` so the node can decrypt common.yaml.
#
# Usage:
#   ./register-node-key.sh <hostname> [--rotate]
#   ./register-node-key.sh hyperion-alpha
#
#   --rotate   Replace an existing bundle (new keys). You must re-flash the
#              node afterwards; its old key stops working.
#
# Replaces the retired flash-identity-usb.sh (the HYPERION-ID USB model is
# gone). The age private key now lives encrypted in-repo and is injected onto
# the NVMe at install time via nixos-anywhere --extra-files.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"
NIXOS_SECRETS_DIR="${REPO_ROOT}/nixos/secrets"
NODE_KEYS_DIR="${REPO_ROOT}/nixos/node-keys"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

usage() {
    cat <<EOF
Usage: $0 <hostname> [--rotate]

  hostname   Hyperion hostname (e.g. hyperion-alpha).
  --rotate   Replace an existing key bundle (requires a re-flash after).

What it does:
  1. Generates a per-node age key + SSH host key.
  2. Writes encrypted nixos/node-keys/<hostname>.tar.age (commit it).
  3. Adds the age pubkey to .sops.yaml and runs sops updatekeys on
     nixos/secrets/*.yaml.
EOF
    exit 1
}

[ $# -ge 1 ] || usage
HOSTNAME="$1"; shift
ROTATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rotate) ROTATE=1 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

[[ "$HOSTNAME" =~ ^hyperion-[a-z]+$ ]] \
    || die "Hostname must match 'hyperion-<greek>' (got: $HOSTNAME)"
[ -f "${REPO_ROOT}/nixos/hosts/${HOSTNAME}.nix" ] \
    || die "No host config at nixos/hosts/${HOSTNAME}.nix"

[ -f "$SOPS_CONFIG" ]                || die "$SOPS_CONFIG not found"
[ -f "$SOPS_AGE_KEY_FILE" ]          || die "Operator age key not found at $SOPS_AGE_KEY_FILE"
command -v age         >/dev/null    || die "age not found on PATH"
command -v age-keygen  >/dev/null    || die "age-keygen not found on PATH"
command -v ssh-keygen  >/dev/null    || die "ssh-keygen not found on PATH"
command -v sops        >/dev/null    || die "sops not found on PATH"
command -v python3     >/dev/null    || die "python3 required for safe YAML edit"
command -v tar         >/dev/null    || die "tar not found on PATH"

mkdir -p "$NODE_KEYS_DIR"
BUNDLE="${NODE_KEYS_DIR}/${HOSTNAME}.tar.age"
if [ -f "$BUNDLE" ] && [ "$ROTATE" -eq 0 ]; then
    die "Bundle already exists: $BUNDLE  (use --rotate to replace; requires re-flash)"
fi

OPERATOR_PUB="$(age-keygen -y "$SOPS_AGE_KEY_FILE")" \
    || die "Could not derive operator pubkey from $SOPS_AGE_KEY_FILE"

# ── Generate keys + build the encrypted bundle ──────────────────────────────
WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

log "Generating per-node age key + SSH host key for ${CYAN}${HOSTNAME}${NC}..."
age-keygen -o "$WORK/age-key.txt" 2>/dev/null
NODE_PUB="$(age-keygen -y "$WORK/age-key.txt")"
ssh-keygen -t ed25519 -N "" -C "$HOSTNAME" -f "$WORK/ssh_host_ed25519_key" -q

# Lay out exactly as it must appear on the target root (/).
install -d -m 0755 "$WORK/tree/var/lib/sops-nix" "$WORK/tree/etc/ssh"
install -m 0600 "$WORK/age-key.txt"               "$WORK/tree/var/lib/sops-nix/key.txt"
install -m 0600 "$WORK/ssh_host_ed25519_key"      "$WORK/tree/etc/ssh/ssh_host_ed25519_key"
install -m 0644 "$WORK/ssh_host_ed25519_key.pub"  "$WORK/tree/etc/ssh/ssh_host_ed25519_key.pub"

log "Encrypting bundle to operator key (${OPERATOR_PUB})..."
tar -C "$WORK/tree" -cf - . | age -e -r "$OPERATOR_PUB" -o "$BUNDLE"
log "  ✓ Wrote $(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"

# ── Register the node's age pubkey in .sops.yaml ────────────────────────────
if grep -qF "$NODE_PUB" "$SOPS_CONFIG"; then
    log "Pubkey already in $SOPS_CONFIG — skipping edit."
else
    log "Appending $NODE_PUB to $SOPS_CONFIG under nixos/secrets rule..."
    python3 - "$SOPS_CONFIG" "$NODE_PUB" <<'PYEOF'
import re, sys
path, pubkey = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().splitlines()

nixos_i = None
for i, l in enumerate(lines):
    if "nixos/secrets" in l and "path_regex" in l:
        nixos_i = i
        break
if nixos_i is None:
    sys.exit("ERROR: nixos/secrets rule not found in .sops.yaml")

age_i = None
for i in range(nixos_i + 1, len(lines)):
    if re.match(r"\s+age:\s*>-?\s*$", lines[i]):
        age_i = i
        break
    if re.match(r"\s*-\s", lines[i]) and not lines[i].lstrip().startswith("- "):
        break
if age_i is None:
    sys.exit("ERROR: 'age: >-' folded-block line not found under the nixos/secrets rule.")

age_indent = len(lines[age_i]) - len(lines[age_i].lstrip())
block_lines = []
for i in range(age_i + 1, len(lines)):
    stripped = lines[i].lstrip()
    if not stripped:
        break
    leading = len(lines[i]) - len(stripped)
    if leading <= age_indent:
        break
    block_lines.append(i)
if not block_lines:
    sys.exit("ERROR: folded-block 'age: >-' has no data lines to extend")

last = block_lines[-1]
stripped_last = lines[last].rstrip()
if not stripped_last.endswith(","):
    lines[last] = stripped_last + ","
indent = lines[last][: len(lines[last]) - len(lines[last].lstrip())]
lines.insert(last + 1, f"{indent}{pubkey}")

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    log "  ✓ Edited $SOPS_CONFIG"
fi

# ── Re-encrypt existing secrets so the node can decrypt them ────────────────
if [ -d "$NIXOS_SECRETS_DIR" ]; then
    shopt -s nullglob
    SECRETS=("$NIXOS_SECRETS_DIR"/*.yaml)
    shopt -u nullglob
    if [ ${#SECRETS[@]} -eq 0 ]; then
        log "No nixos/secrets/*.yaml yet — skipping sops updatekeys."
    else
        for f in "${SECRETS[@]}"; do
            log "sops updatekeys $(basename "$f")..."
            (cd "$REPO_ROOT" && sops updatekeys -y "$f")
        done
    fi
fi

echo ""
log "Done."
echo "  Registered : ${CYAN}$HOSTNAME${NC} → ${CYAN}$NODE_PUB${NC}"
echo ""
echo "Next steps:"
echo "  1. Review:  git diff .sops.yaml nixos/secrets/   (+ git status nixos/node-keys/)"
echo "  2. Commit:"
echo "       git add .sops.yaml nixos/secrets/ nixos/node-keys/${HOSTNAME}.tar.age"
echo "       git commit -m 'feat(hyperion): register ${HOSTNAME} key + re-encrypt secrets'"
echo "  3. Flash:   ./flash-node.sh <ip> ${HOSTNAME}"
