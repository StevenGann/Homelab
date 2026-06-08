#!/bin/bash
# Create the monolithbot config secret from config.json
# Usage: ./create-secret.sh [path/to/config.json]

CONFIG_FILE="${1:-config.json}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.json not found at $CONFIG_FILE"
  echo "Usage: $0 [path/to/config.json]"
  exit 1
fi

kubectl create secret generic monolithbot-config \
  --namespace=monolithbot \
  --from-file=config.json="$CONFIG_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret monolithbot-config created/updated in namespace monolithbot"
