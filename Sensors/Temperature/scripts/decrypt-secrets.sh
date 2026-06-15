#!/usr/bin/env bash
# Regenerate the gitignored plaintext secrets.yaml from the committed SOPS copy.
# Requires the operator age key (default ~/.config/sops/age/keys.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
  sops --decrypt secrets.sops.yaml > secrets.yaml
echo "secrets.yaml written (gitignored)."
