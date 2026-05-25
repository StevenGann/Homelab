#!/usr/bin/env bash
# register-node-key.sh
# Append a per-node Hyperion age pubkey to Hyperion/.sops.yaml and re-encrypt
# any existing nixos/secrets/*.yaml files so the new node can decrypt them.
#
# Run this once per node, after flash-identity-usb.sh prints the pubkey.
#
# Usage:
#   ./register-node-key.sh <hostname> <age-pubkey>
#
# Example:
#   ./register-node-key.sh hyperion-alpha age1abc...xyz
#
# The script is idempotent — re-running with the same pubkey is a no-op.
# Hostname → pubkey mapping is preserved via git history (one commit per
# registration); .sops.yaml itself only lists the pubkeys (the folded YAML
# block can't carry inline comments without polluting the recipient list).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"
NIXOS_SECRETS_DIR="${REPO_ROOT}/nixos/secrets"

usage() {
    echo "Usage: $0 <hostname> <age-pubkey>"
    echo ""
    echo "  hostname    Hyperion hostname (e.g. hyperion-alpha)."
    echo "  age-pubkey  The age1... pubkey printed by flash-identity-usb.sh."
    echo ""
    echo "Examples:"
    echo "  $0 hyperion-alpha age1ABCDEF..."
    echo ""
    echo "What it does:"
    echo "  1. Appends the pubkey to .sops.yaml under the nixos/secrets rule."
    echo "  2. Runs sops updatekeys on existing nixos/secrets/*.yaml files."
    exit 1
}

# ── Args ──────────────────────────────────────────────────────────────────────
[ $# -eq 2 ] || usage

HOSTNAME="$1"
PUBKEY="$2"

[[ "$HOSTNAME" =~ ^hyperion-[a-z]+$ ]] \
    || die "Hostname must match 'hyperion-<greek>' (got: $HOSTNAME)"
[[ "$PUBKEY" =~ ^age1[a-z0-9]+$ ]] \
    || die "Pubkey must look like age1...  (got: $PUBKEY)"

[ -f "$SOPS_CONFIG" ]   || die "$SOPS_CONFIG not found"
command -v python3 >/dev/null || die "python3 required for safe YAML edit"
command -v sops    >/dev/null || die "sops not found on PATH"

# ── Idempotency ──────────────────────────────────────────────────────────────
if grep -qF "$PUBKEY" "$SOPS_CONFIG"; then
    log "Key $PUBKEY already present in $SOPS_CONFIG — skipping edit."
    SKIP_EDIT=1
else
    SKIP_EDIT=0
fi

# ── Edit .sops.yaml ───────────────────────────────────────────────────────────
if [ "$SKIP_EDIT" -eq 0 ]; then
    log "Appending $PUBKEY to $SOPS_CONFIG under nixos/secrets rule..."
    python3 - "$SOPS_CONFIG" "$PUBKEY" <<'PYEOF'
import re, sys
path, pubkey = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().splitlines()

# Find: the nixos/secrets/*.yaml rule
nixos_i = None
for i, l in enumerate(lines):
    if "nixos/secrets" in l and "path_regex" in l:
        nixos_i = i
        break
if nixos_i is None:
    sys.exit("ERROR: nixos/secrets rule not found in .sops.yaml")

# Find: its age: >-  (folded-block) line
age_i = None
for i in range(nixos_i + 1, len(lines)):
    if re.match(r"\s+age:\s*>-?\s*$", lines[i]):
        age_i = i
        break
    # If we hit the next rule (a '- ' at same indent as nixos rule), stop.
    if re.match(r"\s*-\s", lines[i]) and not lines[i].lstrip().startswith("- "):
        break
if age_i is None:
    sys.exit("ERROR: 'age: >-' folded-block line not found under the nixos/secrets rule. "
             "Convert the rule to folded-block form first (see runbook).")

age_indent = len(lines[age_i]) - len(lines[age_i].lstrip())

# Collect indented data lines belonging to this folded block
block_lines = []
for i in range(age_i + 1, len(lines)):
    stripped = lines[i].lstrip()
    if not stripped:
        break  # blank line ends the block
    leading = len(lines[i]) - len(stripped)
    if leading <= age_indent:
        break  # dedent ends the block
    block_lines.append(i)

if not block_lines:
    sys.exit("ERROR: folded-block 'age: >-' has no data lines to extend")

last = block_lines[-1]
# Comma-separate: ensure the previous last line ends with ','
stripped_last = lines[last].rstrip()
if not stripped_last.endswith(","):
    lines[last] = stripped_last + ","

# Insert the new key at the same indent as the existing block lines
indent = lines[block_lines[-1]][: len(lines[block_lines[-1]]) - len(lines[block_lines[-1]].lstrip())]
lines.insert(last + 1, f"{indent}{pubkey}")

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    log "  ✓ Edited $SOPS_CONFIG"
fi

# ── sops updatekeys on any existing nixos/secrets/*.yaml ─────────────────────
if [ -d "$NIXOS_SECRETS_DIR" ]; then
    shopt -s nullglob
    SECRETS=("$NIXOS_SECRETS_DIR"/*.yaml)
    shopt -u nullglob
    if [ ${#SECRETS[@]} -eq 0 ]; then
        log "No nixos/secrets/*.yaml files exist yet — skipping sops updatekeys."
    else
        for f in "${SECRETS[@]}"; do
            log "Running sops updatekeys on $(basename "$f")..."
            (cd "$REPO_ROOT" && sops updatekeys -y "$f")
        done
    fi
else
    warn "$NIXOS_SECRETS_DIR does not exist — skipping sops updatekeys."
fi

echo ""
log "Done."
echo ""
echo "  Registered : ${CYAN}$HOSTNAME${NC} → ${CYAN}$PUBKEY${NC}"
echo ""
echo "Next steps:"
echo "  1. Review the diff:"
echo "       git diff .sops.yaml nixos/secrets/"
echo ""
echo "  2. Commit:"
echo "       git add .sops.yaml nixos/secrets/"
echo "       git commit -m 'feat(hyperion): register $HOSTNAME age key + re-encrypt secrets'"
