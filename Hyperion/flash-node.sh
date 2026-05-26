#!/usr/bin/env bash
# flash-node.sh
# Remotely install NixOS onto a Hyperion node's NVMe via nixos-anywhere.
#
# Prerequisite state (the only hands-on per node):
#   1. Node assembled with a microSD holding the live SD installer
#      (`nix build .#installerSdImage`, dd'd to SD), inserted at assembly.
#   2. EEPROM BOOT_ORDER = 0xf16 (NVMe -> SD -> loop). A blank NVMe falls
#      through to the SD installer; ./configure-eeprom.sh sets this.
#   3. Node powered on, booted the SD installer, reachable over SSH, and you
#      know its DHCP IP (assign a UCG reservation in .101..110 first).
#   4. ./register-node-key.sh <hostname> has been run + committed, so the
#      per-node age key exists in nixos/node-keys/ and common.yaml is
#      re-encrypted to it.
#
# Then, from the workstation:
#   ./flash-node.sh <ip> <hostname>
#   ./flash-node.sh 192.168.10.101 hyperion-alpha
#
# What it does:
#   - Decrypts the per-node age key + SSH host key from nixos/node-keys/
#     into a private temp tree (--extra-files layout).
#   - Runs nixos-anywhere: disko partitions /dev/nvme0n1 (from the host
#     closure), the closure is built ON the node (--build-on-remote, pulling
#     from Cachix), the key + host keys are injected, and the node reboots.
#   - kexec is skipped (--phases disko,install,reboot) because it is broken
#     on the Pi and the target is already a NixOS installer.
#
# After reboot the EEPROM finds a valid NVMe and boots NixOS; the SD stays
# resident and ignored. Day-2 changes go through `colmena apply`, not this.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
NODE_KEYS_DIR="${FLAKE_DIR}/node-keys"

# Pinned nixos-anywhere — a tool we `nix run`, deliberately not a flake input
# (it would otherwise enter flake.lock and every closure). Bump intentionally.
NIXOS_ANYWHERE_REF="github:nix-community/nixos-anywhere/1.13.0"

# Operator age identity — same file used for sops elsewhere in this repo.
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

usage() {
    cat <<EOF
Usage: $0 <ip> <hostname>

  ip        DHCP address of the node booted into the SD installer.
  hostname  Target host (e.g. hyperion-alpha); must match hosts/<hostname>.nix.

Example:
  $0 192.168.10.101 hyperion-alpha

Prerequisites: see the header of this script and
docs/runbooks/remote-flash-a-node.md.
EOF
    exit 1
}

[ $# -eq 2 ] || usage
NODE_IP="$1"
HOSTNAME="$2"

# ── Validate ───────────────────────────────────────────────────────────────
[[ "$HOSTNAME" =~ ^hyperion-[a-z]+$ ]] \
    || die "Hostname must match 'hyperion-<greek>' (got: $HOSTNAME)"
[[ "$NODE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || die "IP looks malformed (got: $NODE_IP)"

[ -f "${FLAKE_DIR}/hosts/${HOSTNAME}.nix" ] \
    || die "No host config at nixos/hosts/${HOSTNAME}.nix"

KEY_BUNDLE="${NODE_KEYS_DIR}/${HOSTNAME}.tar.age"
[ -f "$KEY_BUNDLE" ] \
    || die "No key bundle at ${KEY_BUNDLE}. Run: ./register-node-key.sh ${HOSTNAME}"

[ -f "$SOPS_AGE_KEY_FILE" ] \
    || die "Operator age key not found at ${SOPS_AGE_KEY_FILE} (set SOPS_AGE_KEY_FILE)"

command -v age >/dev/null || die "age not found on PATH"
command -v nix >/dev/null || die "nix not found on PATH (needed to run nixos-anywhere)"
command -v tar >/dev/null || die "tar not found on PATH"

# ── Stage the --extra-files tree from the encrypted bundle ──────────────────
# The bundle is a tar of the exact on-target layout:
#   ./var/lib/sops-nix/key.txt
#   ./etc/ssh/ssh_host_ed25519_key{,.pub}
EXTRA="$(mktemp -d)"
chmod 700 "$EXTRA"
cleanup() { rm -rf "$EXTRA"; }
trap cleanup EXIT

log "Decrypting per-node key bundle for ${CYAN}${HOSTNAME}${NC}..."
age -d -i "$SOPS_AGE_KEY_FILE" "$KEY_BUNDLE" | tar -xf - -C "$EXTRA" \
    || die "Failed to decrypt/unpack ${KEY_BUNDLE} (wrong operator key?)"

# Defensive perms — nixos-anywhere preserves source modes onto the target.
[ -f "$EXTRA/var/lib/sops-nix/key.txt" ] \
    || die "Bundle missing var/lib/sops-nix/key.txt — re-run register-node-key.sh"
chmod 600 "$EXTRA/var/lib/sops-nix/key.txt"
[ -f "$EXTRA/etc/ssh/ssh_host_ed25519_key" ] && chmod 600 "$EXTRA/etc/ssh/ssh_host_ed25519_key"

# ── Confirm — this wipes the NVMe ───────────────────────────────────────────
echo ""
warn "About to ERASE /dev/nvme0n1 on ${NODE_IP} and install NixOS as ${HOSTNAME}."
warn "The node must be booted into the SD installer (not a production node)."
read -r -p "Type the hostname to confirm: " CONFIRM
[ "$CONFIRM" = "$HOSTNAME" ] || die "Confirmation mismatch — aborting."

# ── Run nixos-anywhere ──────────────────────────────────────────────────────
log "Installing ${HOSTNAME} onto ${NODE_IP} (build-on-remote; kexec skipped)..."
nix run "$NIXOS_ANYWHERE_REF" -- \
    --flake "${FLAKE_DIR}#${HOSTNAME}" \
    --target-host "root@${NODE_IP}" \
    --build-on-remote \
    --phases disko,install,reboot \
    --extra-files "$EXTRA"

echo ""
log "Done. ${CYAN}${HOSTNAME}${NC} is rebooting into NixOS from NVMe."
echo ""
echo "Verify once it is back up:"
echo "  ssh owner@${NODE_IP} 'hostnamectl; systemctl status k3s --no-pager | head'"
echo "  kubectl get nodes        # ${HOSTNAME} should reach Ready"
echo ""
echo "Day-2 changes from here use Colmena, not this script:"
echo "  cd nixos && colmena apply --on ${HOSTNAME}"
