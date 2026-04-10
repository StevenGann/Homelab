#!/usr/bin/env bash
# reimage.sh
# Reboots one or more Hyperion nodes so they re-image from the Bootstrap SD card.
#
# Prerequisites before running:
#   1. The Bootstrap SD card is physically inserted in the target node(s).
#   2. The node's identity USB (HYPERION-ID) is also inserted.
#   3. EEPROM BOOT_ORDER is 0xf61 (SD → NVMe → loop).
#
# On reboot the Pi will find the SD card first and run the Bootstrap IMG,
# which will update the identity USB cache if a newer Node IMG is available,
# then flash NVMe, repartition, and reboot into NVMe automatically.
#
# Usage:
#   ./reimage.sh all                        # reboot all 10 nodes
#   ./reimage.sh hyperion-alpha             # reboot one node
#   ./reimage.sh alpha beta                 # reboot two nodes
#   ./reimage.sh all --user <username>      # override SSH user (default: owner)
#   ./reimage.sh all --no-confirm           # skip the "are you sure" prompt
set -euo pipefail

NODES=(alpha beta gamma delta epsilon zeta eta theta iota kappa)
SSH_USER="owner"

declare -A NODE_IPS=(
    [alpha]=192.168.10.101
    [beta]=192.168.10.102
    [gamma]=192.168.10.103
    [delta]=192.168.10.104
    [epsilon]=192.168.10.105
    [zeta]=192.168.10.106
    [eta]=192.168.10.107
    [theta]=192.168.10.108
    [iota]=192.168.10.109
    [kappa]=192.168.10.110
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <node|all> [node...] [--user <username>] [--no-confirm]"
    echo ""
    echo "  all                → target all 10 nodes"
    echo "  hyperion-<greek>   → target a single node (hyperion- prefix optional)"
    echo "  --user <name>      → SSH username (default: owner)"
    echo "  --no-confirm       → skip confirmation prompt"
    echo ""
    echo "Examples:"
    echo "  $0 all"
    echo "  $0 hyperion-alpha"
    echo "  $0 alpha beta gamma"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
[ $# -gt 0 ] || usage

TARGET_NODES=()
NO_CONFIRM=false

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            shift
            [ $# -gt 0 ] || die "--user requires a username argument"
            SSH_USER="$1"
            ;;
        --no-confirm)
            NO_CONFIRM=true
            ;;
        all)
            TARGET_NODES=("${NODES[@]}")
            ;;
        *)
            NODE_ARG="${1#hyperion-}"
            [[ " ${NODES[*]} " == *" $NODE_ARG "* ]] \
                || die "Unknown node: $1. Valid names: ${NODES[*]}"
            TARGET_NODES+=("$NODE_ARG")
            ;;
    esac
    shift
done

[ ${#TARGET_NODES[@]} -gt 0 ] || usage

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
warn "This will reboot the following node(s) into the Bootstrap SD card:"
for n in "${TARGET_NODES[@]}"; do
    echo -e "  ${CYAN}hyperion-$n${NC}  (${NODE_IPS[$n]})"
done
echo ""
warn "Ensure the Bootstrap SD card AND identity USB are physically inserted before proceeding."
echo ""

if [ "$NO_CONFIRM" = false ]; then
    read -r -p "Proceed? [y/N] " resp
    [[ "$resp" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    echo ""
fi

# ── Reboot each node ──────────────────────────────────────────────────────────
FAILED=()

reboot_node() {
    local greek="$1"
    local hostname="hyperion-$greek"
    local ip="${NODE_IPS[$greek]}"

    log "Rebooting $hostname ($ip)..."

    if ssh \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "$SSH_USER@$ip" \
        "sudo reboot" 2>/dev/null; then
        log "  ${GREEN}Reboot initiated.${NC}"
    else
        # SSH exits non-zero when the connection drops due to reboot — that's expected.
        # Treat exit code 255 (connection closed) as success; anything else is a real error.
        local rc=$?
        if [ "$rc" -eq 255 ]; then
            log "  ${GREEN}Reboot initiated (connection closed — expected).${NC}"
        else
            warn "Failed to reboot $hostname (exit $rc). Is it reachable as $SSH_USER@$ip?"
            FAILED+=("$hostname")
        fi
    fi
}

for greek in "${TARGET_NODES[@]}"; do
    reboot_node "$greek"
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    warn "The following nodes could not be rebooted: ${FAILED[*]}"
    warn "Check SSH connectivity and ensure nodes are running."
    exit 1
else
    log "All targeted nodes are rebooting into the Bootstrap SD card."
    log "Monitor progress by watching each node's bootstrap.log on the identity USB,"
    log "or by connecting a serial cable (ttyAMA0, 115200 baud)."
fi
