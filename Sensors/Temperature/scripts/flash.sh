#!/usr/bin/env bash
# Flash (or OTA-update) a Temperature node.
# Usage: ./scripts/flash.sh nodes/temp-living-room.yaml
set -euo pipefail
cd "$(dirname "$0")/.."

NODE="${1:?usage: ./scripts/flash.sh nodes/<node>.yaml}"

# Regenerate plaintext secrets.yaml from the committed SOPS copy when present.
# (secrets.yaml is gitignored; secrets.sops.yaml is the committed source of truth.)
if [ -f secrets.sops.yaml ]; then
  ./scripts/decrypt-secrets.sh
fi

if [ ! -f secrets.yaml ]; then
  echo "ERROR: secrets.yaml missing and no secrets.sops.yaml to decrypt." >&2
  echo "       Either run ./scripts/decrypt-secrets.sh, or copy secrets.yaml.example -> secrets.yaml." >&2
  exit 1
fi

# First flash auto-detects USB (/dev/ttyUSB0); later runs offer the OTA target.
exec esphome run "$NODE"
