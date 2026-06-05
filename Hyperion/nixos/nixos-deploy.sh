#!/usr/bin/env bash
# nixos-deploy.sh — push a day-2 NixOS config change to Hyperion worker(s).
#
# WHY THIS EXISTS (not `colmena apply`):
#   The flake builds workers with the custom `nixos-raspberrypi.lib.nixosSystem`
#   builder, which injects a `nixos-raspberrypi` module argument. Colmena 0.4.0's
#   hive evaluates with the stock `lib.nixosSystem` + `meta.specialArgs={inherit
#   inputs;}`, so the Pi modules fail with `attribute 'nixos-raspberrypi'
#   missing`. Until the hive is taught the custom builder, day-2 pushes go
#   through this script instead.
#
# WHAT IT DOES (per node):
#   1. rsync this nixos/ tree to /home/owner/hyperion-nixos on the node
#   2. ssh in and `sudo nixos-rebuild switch --flake .#<node>` (builds NATIVELY
#      on the aarch64 Pi from substituters — the x86 workstation cannot build
#      aarch64 and has no remote builders/binfmt configured)
#
# This uses the exact `nixosConfigurations.<node>` attribute that CI eval-checks
# and that `nix eval` validates locally.
#
# USAGE:
#   ./nixos-deploy.sh hyperion-alpha            # one node
#   ./nixos-deploy.sh hyperion-alpha hyperion-beta
#   ./nixos-deploy.sh all                        # all 10, serially
#   ./nixos-deploy.sh all --parallel             # all 10, backgrounded
set -euo pipefail

cd "$(dirname "$0")"

# Greek-letter name -> last IP octet (alpha=101 .. kappa=110), matching flake.nix.
declare -A OCTET=(
  [hyperion-alpha]=101 [hyperion-beta]=102 [hyperion-gamma]=103
  [hyperion-delta]=104 [hyperion-epsilon]=105 [hyperion-zeta]=106
  [hyperion-eta]=107 [hyperion-theta]=108 [hyperion-iota]=109
  [hyperion-kappa]=110
)
ALL=(hyperion-alpha hyperion-beta hyperion-gamma hyperion-delta hyperion-epsilon
     hyperion-zeta hyperion-eta hyperion-theta hyperion-iota hyperion-kappa)

PARALLEL=0
NODES=()
for arg in "$@"; do
  case "$arg" in
    all)        NODES=("${ALL[@]}") ;;
    --parallel) PARALLEL=1 ;;
    hyperion-*) NODES+=("$arg") ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done
[[ ${#NODES[@]} -eq 0 ]] && { echo "usage: $0 <node|all> [...] [--parallel]" >&2; exit 2; }

# Persisted per-node SSH host keys (set at install) are trusted on first
# contact; accept-new pins them without prompting and still detects changes.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

deploy_one() {
  local node="$1" ip="192.168.10.${OCTET[$1]}"
  echo "[$node] rsync -> $ip"
  rsync -a --delete --exclude='.git' -e "ssh ${SSH_OPTS[*]}" \
    ./ "owner@${ip}:/home/owner/hyperion-nixos/"
  echo "[$node] nixos-rebuild switch"
  ssh "${SSH_OPTS[@]}" "owner@${ip}" \
    "cd /home/owner/hyperion-nixos && sudo nixos-rebuild switch --flake .#${node}"
  echo "[$node] done"
}

rc=0
if [[ $PARALLEL -eq 1 ]]; then
  for node in "${NODES[@]}"; do deploy_one "$node" & done
  wait || rc=$?
else
  for node in "${NODES[@]}"; do deploy_one "$node" || rc=$?; done
fi
exit $rc
