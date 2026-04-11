#!/usr/bin/env bash
# configure-eeprom.sh
# Sets BOOT_ORDER=0xf61 (SD → NVMe → loop) on Hyperion Pi 5 nodes via SSH.
# Run once per node (or after replacing the EEPROM SPI flash).
#
# Requires: sshpass  (sudo apt-get install sshpass)
#
# Usage: ./configure-eeprom.sh [node-name] [--reboot|--no-reboot] [--user <username>] [--boot-order <value>]
#   No node arg         → configure all 10 nodes in order
#   Node name           → configure a single node (e.g. hyperion-alpha or alpha)
#   --reboot            → reboot each node after applying (no prompt)
#   --no-reboot         → skip reboot after applying (no prompt)
#   --user <name>       → SSH username (default: pi)
#   --boot-order <hex>  → target BOOT_ORDER value (default: 0xf61)
#
# Boot order nibbles are read right-to-left:
#   0xf61   SD(1) → NVMe(6) → loop(f)  ← normal operating mode
#   0xf612  network(2) → SD(1) → NVMe(6) → loop(f)  ← use to configure via netboot
set -euo pipefail

NODES=(alpha beta gamma delta epsilon zeta eta theta iota kappa)
SSH_USER="pi"
TARGET_BOOT_ORDER="0xf641"

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

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
TARGET_NODES=()
REBOOT_MODE="prompt"  # prompt | yes | no

while [ $# -gt 0 ]; do
    case "$1" in
        --reboot)    REBOOT_MODE="yes" ;;
        --no-reboot) REBOOT_MODE="no" ;;
        --user)
            shift
            [ $# -gt 0 ] || die "--user requires a username argument"
            SSH_USER="$1"
            ;;
        --boot-order)
            shift
            [ $# -gt 0 ] || die "--boot-order requires a value (e.g. 0xf6)"
            TARGET_BOOT_ORDER="$1"
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

[ ${#TARGET_NODES[@]} -eq 0 ] && TARGET_NODES=("${NODES[@]}")

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v sshpass >/dev/null \
    || die "sshpass not found. Install it: sudo apt-get install sshpass"

# ── Banner + password prompt ──────────────────────────────────────────────────
echo ""
log "=== Hyperion EEPROM Boot Order Configuration ==="
log "Nodes:      ${TARGET_NODES[*]}"
log "Boot order: $TARGET_BOOT_ORDER  (SD card → USB → NVMe → loop)"
echo ""

read -r -s -p "SSH password for $SSH_USER@hyperion-*: " PI_PASSWORD
echo ""
echo ""

# ── Reboot decision ───────────────────────────────────────────────────────────
if [ "$REBOOT_MODE" = "prompt" ]; then
    read -r -p "Reboot each node after applying EEPROM config? [y/N] " _resp
    [[ "$_resp" =~ ^[Yy]$ ]] && REBOOT_MODE="yes" || REBOOT_MODE="no"
    echo ""
fi

# ── Configure one node ────────────────────────────────────────────────────────
configure_node() {
    local greek="$1"
    local hostname="hyperion-$greek"
    local ip="${NODE_IPS[$greek]}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node: $hostname  ($ip)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Wrapper: run a command on the node via SSH with password auth
    ssh_run() {
        sshpass -p "$PI_PASSWORD" ssh \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -o BatchMode=no \
            "$SSH_USER@$ip" "$@"
    }

    # Test connectivity before proceeding
    log "Connecting to $hostname..."
    if ! ssh_run true 2>/dev/null; then
        warn "Cannot reach $hostname at $ip. Skipping."
        return
    fi

    # Read current EEPROM config
    log "Reading EEPROM config..."
    local current_config
    if ! current_config="$(ssh_run sudo rpi-eeprom-config 2>/dev/null)"; then
        warn "rpi-eeprom-config failed on $hostname. Is rpi-eeprom installed? Skipping."
        return
    fi

    local current_order
    current_order="$(echo "$current_config" | grep '^BOOT_ORDER=' | cut -d= -f2 || true)"
    log "  Current BOOT_ORDER: ${current_order:-<not set>}"

    if [ "$current_order" = "$TARGET_BOOT_ORDER" ]; then
        log "  Already $TARGET_BOOT_ORDER. Nothing to do."
        return
    fi

    # Patch BOOT_ORDER in the config text
    local new_config
    if echo "$current_config" | grep -q '^BOOT_ORDER='; then
        new_config="$(echo "$current_config" | sed "s/^BOOT_ORDER=.*/BOOT_ORDER=$TARGET_BOOT_ORDER/")"
    else
        new_config="${current_config}"$'\n'"BOOT_ORDER=$TARGET_BOOT_ORDER"
    fi

    # Ship the new config and apply it
    log "Applying BOOT_ORDER=$TARGET_BOOT_ORDER..."
    echo "$new_config" | ssh_run \
        "cat > /tmp/hyperion-bootconf.txt && sudo rpi-eeprom-config --apply /tmp/hyperion-bootconf.txt && rm /tmp/hyperion-bootconf.txt"

    log "  ${GREEN}EEPROM config staged successfully.${NC}"

    # Reboot
    if [ "$REBOOT_MODE" = "yes" ]; then
        log "Rebooting $hostname..."
        ssh_run sudo reboot || true  # SSH closes on reboot — ignore the disconnect error
        log "  Reboot initiated. The new boot order takes effect after POST."
    else
        log "  Skipping reboot. Run 'sudo reboot' on $hostname when ready."
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for greek in "${TARGET_NODES[@]}"; do
    configure_node "$greek"
done

echo ""
log "=== Done ==="
if [ "$REBOOT_MODE" = "no" ]; then
    warn "EEPROM changes are staged but will not take effect until each node is rebooted."
fi
