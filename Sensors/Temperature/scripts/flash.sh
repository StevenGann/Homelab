#!/usr/bin/env bash
# Flash (or OTA-update) a Temperature node.
# Usage: ./scripts/flash.sh nodes/temp-living-room.yaml
set -euo pipefail
cd "$(dirname "$0")/.."

NODE="${1:?usage: ./scripts/flash.sh nodes/<node>.yaml}"

# DEFERRED (once SOPS+age key exists on this workstation):
#   SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
#     sops --decrypt secrets.sops.yaml > secrets.yaml
# For now, secrets.yaml is a plaintext placeholder file (gitignored).

if [ ! -f secrets.yaml ]; then
  echo "ERROR: secrets.yaml missing. Copy secrets.yaml.example -> secrets.yaml and fill it in." >&2
  exit 1
fi

# First flash auto-detects USB (/dev/ttyUSB0); later runs offer the OTA target.
exec esphome run "$NODE"
