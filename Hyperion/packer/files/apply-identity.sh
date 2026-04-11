#!/bin/bash
# apply-identity.sh
# Reads the node hostname from the HYPERION-ID USB stick and applies it.
# Runs once on first NVMe boot via apply-identity.service.
# Guard file /etc/hyperion-identity-applied prevents re-application.
set -euo pipefail

GUARD=/etc/hyperion-identity-applied
[ -f "$GUARD" ] && exit 0

# Wait for USB enumeration (up to 15 s; less contention on NVMe boot than Bootstrap)
ID_DEV=""
for i in $(seq 1 15); do
    ID_DEV=$(blkid -L HYPERION-ID 2>/dev/null) && break
    sleep 1
done

if [ -z "${ID_DEV:-}" ]; then
    echo "apply-identity: no HYPERION-ID USB found — hostname unchanged" >&2
    exit 0
fi

ID_MNT=$(mktemp -d)
trap "umount $ID_MNT 2>/dev/null || true; rm -rf $ID_MNT" EXIT
mount -o ro "$ID_DEV" "$ID_MNT"

HOSTNAME=$(tr -d '[:space:]' < "$ID_MNT/hostname")
[ -n "$HOSTNAME" ] || { echo "apply-identity: hostname file empty" >&2; exit 1; }

hostnamectl set-hostname "$HOSTNAME"
grep -qF "$HOSTNAME" /etc/hosts || echo "127.0.1.1  $HOSTNAME" >> /etc/hosts

touch "$GUARD"
echo "apply-identity: hostname set to $HOSTNAME"
