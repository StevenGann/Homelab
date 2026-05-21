#!/usr/bin/env bash
# watch-flash.sh
# Realtime view of a Hyperion node's flashing progress.
#
# Polls the node's :8080/ JSON status and :8080/log log tail every 2 seconds.
# Detects the "two `done` events bracketing a reboot" pattern that signals it
# is safe to remove the Bootstrap medium (USB stick / SD card, whichever is in
# use). Without this tool the operator has to either keep an SSH session open
# and tail journalctl on each Pi, or wait until flashing has already failed.
#
# Operator UI language deliberately says "Bootstrap medium" rather than "SD" —
# the current fleet boots from USB sticks; SD support is retained in the design
# but is not currently exercised. Pulling the wrong medium at the wrong moment
# is the H5 failure mode in Hyperion/docs/runbooks/debug-flashing.md.
#
# Usage:
#   ./watch-flash.sh <node>                 # 2-pane view via tmux
#   ./watch-flash.sh --single-pane <node>   # status only (skip tmux)
#   ./watch-flash.sh --status-only <node>   # internal: status pane body
#   ./watch-flash.sh --log-only <node>      # internal: log pane body
#
# <node> can be:
#   - a Greek-letter shorthand: alpha, beta, ..., kappa
#   - a hostname:               hyperion-alpha (looked up via getent)
#   - an IP address:            192.168.10.101
#
# Requires: bash 4+, curl, jq. Optional: tmux for the 2-pane view.
set -euo pipefail

# ── Node IP map (mirrors reimage.sh) ──────────────────────────────────────────
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

# ── Arg parsing ───────────────────────────────────────────────────────────────
MODE=full
NODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --single-pane) MODE=single; shift ;;
        --status-only) MODE=status;  shift ;;
        --log-only)    MODE=log;     shift ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail/p' "$0" | sed -n 's|^# \{0,1\}||p'
            exit 0
            ;;
        --) shift; break ;;
        -*) echo "unknown flag: $1" >&2; exit 2 ;;
        *)  NODE="$1"; shift ;;
    esac
done

[ -n "$NODE" ] || { echo "usage: $0 [--single-pane] <node>" >&2; exit 2; }

# ── Resolve <node> → IP ───────────────────────────────────────────────────────
resolve_node_ip() {
    local n="$1"
    # IP literal
    if [[ "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$n"; return 0
    fi
    # Greek-letter shorthand
    if [ -n "${NODE_IPS[$n]:-}" ]; then
        echo "${NODE_IPS[$n]}"; return 0
    fi
    # hyperion-<letter> form
    local short="${n#hyperion-}"
    if [ -n "${NODE_IPS[$short]:-}" ]; then
        echo "${NODE_IPS[$short]}"; return 0
    fi
    # Last resort: getent / DNS
    local ip
    ip=$(getent hosts "$n" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$ip" ]; then
        echo "$ip"; return 0
    fi
    return 1
}

NODE_IP=$(resolve_node_ip "$NODE") || {
    echo "could not resolve <node>=$NODE to an IP" >&2
    echo "valid shorthands: ${!NODE_IPS[*]}" >&2
    exit 2
}

STATUS_URL="http://$NODE_IP:8080/"
LOG_URL="http://$NODE_IP:8080/log"

# Colors are emitted unconditionally; tmux/terminals strip them when not a TTY.
B=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'

# ── Dispatch: full-mode forks into tmux; pane modes do the actual work ────────
if [ "$MODE" = "full" ]; then
    if ! command -v tmux >/dev/null 2>&1; then
        echo "tmux not found — falling back to single-pane mode." >&2
        echo "Install tmux for the 2-pane (status + log) layout." >&2
        MODE=single
    fi
fi

if [ "$MODE" = "full" ]; then
    SESSION="watch-flash-${NODE}-$$"
    # Top pane: status + state machine. Bottom pane: log tail (40% height).
    tmux new-session -d -s "$SESSION" \
        "$(readlink -f "$0") --status-only $NODE; read -r -p 'press Enter to close' _"
    tmux split-window -t "$SESSION" -v -p 40 \
        "$(readlink -f "$0") --log-only $NODE; read -r -p 'press Enter to close' _"
    tmux select-pane -t "$SESSION" -U
    tmux set-option -t "$SESSION" status off
    exec tmux attach -t "$SESSION"
fi

# ── Helpers shared by status and log panes ────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/watch-flash.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

poll_status() {
    # 0 on success (JSON written to $TMPDIR/status.json); non-zero on failure.
    curl -sf --connect-timeout 2 --max-time 3 "$STATUS_URL" \
        -o "$TMPDIR/status.json" 2>/dev/null
}

poll_log() {
    curl -sf --connect-timeout 2 --max-time 3 "$LOG_URL?n=200" \
        -o "$TMPDIR/log.txt" 2>/dev/null
}

# ── Log-only pane ─────────────────────────────────────────────────────────────
if [ "$MODE" = "log" ]; then
    while true; do
        clear
        printf '%s[log %s @ %s — %s]%s\n' "$DIM" "$NODE" "$NODE_IP" "$(date '+%H:%M:%S')" "$RST"
        if poll_log; then
            tail -n "$(( $(tput lines 2>/dev/null || echo 30) - 2 ))" "$TMPDIR/log.txt"
        else
            printf '%s(:8080/log unreachable — Pi may be rebooting or offline)%s\n' "$YLW" "$RST"
        fi
        sleep 2
    done
fi

# ── Status / state-machine pane ───────────────────────────────────────────────
#
# READY-TO-REMOVE detector — addresses BLOCKER C6 / Tier 1.1 of FINAL.md.
#
# The naive "no state change in 60s" heuristic that an earlier draft proposed is
# WRONG: it fires on a cycle-2 stall (HYPERION-ID dislodged, phase=usb_wait)
# which is the H5 misidentified-success failure mode.
#
# The CORRECT signature is the sequence:
#   1. status=done (first cycle: NVMe was flashed and Pi is about to reboot)
#   2. :8080 unreachable for ≥ MIN_REBOOT_GAP and ≤ MAX_REBOOT_GAP seconds
#      (the Pi powers off, kernel boots, bootstrap.service restarts)
#   3. status != done (second cycle: bootstrap re-running because medium is
#      still in place; sees NVMe-current and is about to reboot again)
#   4. status=done (second `done` event — the Pi has now done one
#      "verification" boot since the flash succeeded)
#
# After (4), it is safe to remove the Bootstrap medium. The Pi's NEXT boot
# (with no medium present) goes straight to NVMe per BOOT_ORDER=0xf641.
#
# Edge cases handled:
#   - poll-failure gap < MIN_REBOOT_GAP: treat as a transient network blip,
#     stay in FIRST_DONE rather than progressing.
#   - poll-failure gap > MAX_REBOOT_GAP: flag a warning but accept the resumed
#     poll. Some imaging cycles take longer (slow USB, large image, etc.).
#   - status returns to non-done without a poll-failure gap (Pi never
#     rebooted, just re-entered the bootstrap loop): treat that as a new run,
#     reset to INIT.
MIN_REBOOT_GAP=15
MAX_REBOOT_GAP=180

state=INIT
first_done_at=0
unreachable_since=0
warn_msg=""
last_phase=""
last_status=""
last_step=""
last_message=""
last_attempt=""
last_image_server=""
last_usb_version=""
last_nvme_version=""

phase_color() {
    case "$1" in
        done)                                   echo "$GRN" ;;
        error)                                  echo "$RED" ;;
        downloading|flashing|flashing_*)        echo "$YLW" ;;
        working|verifying|repartition_*)        echo "$CYN" ;;
        usb_wait|network_wait|exhausted_*)      echo "$YLW" ;;
        starting)                               echo "$BLU" ;;
        *)                                      echo "$RST" ;;
    esac
}

render() {
    local now ts gap
    now=$(date +%s)
    ts=$(date '+%H:%M:%S')

    clear
    printf '%s== watch-flash %s @ %s ===========================================%s\n' \
        "$B" "$NODE" "$NODE_IP" "$RST"
    printf '%spoll @ %s — state=%s%s\n\n' "$DIM" "$ts" "$state" "$RST"

    if [ -z "$last_status" ]; then
        printf '%s(no successful poll yet — :8080 unreachable)%s\n' "$YLW" "$RST"
    else
        local color
        color=$(phase_color "$last_phase")
        printf '  phase            : %s%s%s\n' "$color" "$last_phase" "$RST"
        printf '  status           : %s%s%s\n' "$color" "$last_status" "$RST"
        printf '  step             : %s\n'   "$last_step"
        printf '  attempt          : %s\n'   "$last_attempt"
        printf '  message          : %s\n'   "$last_message"
        printf '  image-server     : %s%s%s\n' "$CYN" "$last_image_server" "$RST"
        printf '  USB cache ver    : %s\n'   "${last_usb_version:-(null)}"
        printf '  NVMe ver         : %s\n'   "${last_nvme_version:-(null)}"
    fi

    case "$state" in
        FIRST_DONE)
            printf '\n%sFirst `done` observed %ds ago — waiting for reboot.%s\n' \
                "$DIM" "$(( now - first_done_at ))" "$RST"
            ;;
        REBOOTING)
            gap=$(( now - unreachable_since ))
            printf '\n%s:8080 unreachable for %ds (expected %d–%ds for a reboot).%s\n' \
                "$DIM" "$gap" "$MIN_REBOOT_GAP" "$MAX_REBOOT_GAP" "$RST"
            ;;
        SECOND_BOOT)
            printf '\n%sSecond boot cycle in progress — waiting for second `done`.%s\n' \
                "$DIM" "$RST"
            ;;
        SECOND_DONE)
            printf '\n%s═════════════════════════════════════════════════════════════%s\n' "$GRN$B" "$RST"
            printf '%s  READY TO REMOVE BOOTSTRAP MEDIUM  (%s)%s\n'                       "$GRN$B" "$NODE" "$RST"
            printf '%s═════════════════════════════════════════════════════════════%s\n' "$GRN$B" "$RST"
            printf '\nThe Pi has completed two consecutive bootstrap cycles ending in\n'
            printf '`done`, with a %ds-%ds gap between them. The flash is verified.\n'   "$MIN_REBOOT_GAP" "$MAX_REBOOT_GAP"
            printf 'Pull the Bootstrap USB stick (or SD card, if used) now. The next\n'
            printf 'boot will go straight to NVMe per BOOT_ORDER=0xf641.\n'
            ;;
    esac

    if [ -n "$warn_msg" ]; then
        printf '\n%sWARN: %s%s\n' "$YLW" "$warn_msg" "$RST"
    fi
}

while true; do
    now=$(date +%s)
    if poll_status; then
        last_status=$(jq -r '.status // ""'             "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_phase=$(jq -r  '.phase  // ""'             "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_step=$(jq -r   '.step   // ""'             "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_message=$(jq -r '.message // ""'           "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_attempt=$(jq -r '.attempt // ""'           "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_image_server=$(jq -r '.image_server_base // "(unset)"' "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_usb_version=$(jq -r '.usb_version // ""'   "$TMPDIR/status.json" 2>/dev/null || echo "")
        last_nvme_version=$(jq -r '.nvme_version // ""' "$TMPDIR/status.json" 2>/dev/null || echo "")

        case "$state" in
            INIT)
                if [ "$last_status" = "done" ]; then
                    state=FIRST_DONE
                    first_done_at=$now
                fi
                ;;
            FIRST_DONE)
                # Still reachable. Stay until either we see status leave `done`
                # (Pi has somehow re-entered bootstrap without losing :8080 —
                # unusual; treat as the second cycle starting) or :8080 dies.
                if [ "$last_status" != "done" ]; then
                    state=SECOND_BOOT
                fi
                ;;
            REBOOTING)
                reboot_gap=$(( now - unreachable_since ))
                if [ "$last_status" = "done" ] && [ "$reboot_gap" -lt "$MIN_REBOOT_GAP" ]; then
                    # Network blip masquerading as a reboot. Roll back.
                    state=FIRST_DONE
                elif [ "$reboot_gap" -gt "$MAX_REBOOT_GAP" ]; then
                    warn_msg="Reboot took ${reboot_gap}s — longer than expected ${MAX_REBOOT_GAP}s."
                    state=SECOND_BOOT
                else
                    state=SECOND_BOOT
                fi
                ;;
            SECOND_BOOT)
                if [ "$last_status" = "done" ]; then
                    state=SECOND_DONE
                fi
                ;;
            SECOND_DONE)
                : # terminal
                ;;
        esac
        unreachable_since=0
    else
        case "$state" in
            FIRST_DONE)
                state=REBOOTING
                unreachable_since=$now
                ;;
            REBOOTING)
                : # still down — accumulate time
                ;;
            INIT|SECOND_BOOT|SECOND_DONE)
                # Treat as a transient unreachability; do not transition.
                : ;;
        esac
    fi

    render
    sleep 2
done
