#!/usr/bin/env bash
# Heimdall — Technitium blocklist subscription IaC
#
# Declares the set of blocklist URLs Technitium should subscribe to, plus the
# core blocking settings (enable flag, blocking type, update interval). Each
# run reconciles Technitium to match the declared set.
#
# CONTRACT — different from seed-zones.sh:
#   - seed-zones.sh is ADDITIVE-ONLY for records: operator UI-added records persist.
#   - seed-blocklists.sh is RECONCILING for blocklist URLs: this script's
#     BLOCK_LIST_URLS array IS the canonical set. UI-added URLs not in the array
#     are REMOVED on next run.
#
#     Why the difference: DNS records are user data (one-off additions during
#     testing happen routinely). Blocklist subscriptions are configuration —
#     deliberate, infrequent, and the user explicitly asked for IaC management.
#     To keep an extra blocklist permanently, add it to BLOCK_LIST_URLS below.
#
# Empirically verified against Technitium v15.2.0:
#   - POST /api/settings/set?token=X&blockListUrls=url1,url2,...  (comma-separated)
#   - POST /api/settings/forceUpdateBlockLists?token=X  (trigger immediate fetch)
#   - GET  /api/settings/get?token=X  (read back current state)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
DNS_API="${DNS_API:-http://127.0.0.1:5380}"
ADMIN_PW_FILE="${ADMIN_PW_FILE:-/opt/Homelab/Heimdall/secrets/technitium-admin-pw}"
TOKEN_FILE="${TOKEN_FILE:-/tmp/heimdall-technitium-token}"

# ─── Declared blocklist URLs ─────────────────────────────────────────────────────────
# Curated set covering ads, trackers, malware, and phishing. To add or remove a
# subscription, edit this array, commit, and re-deploy. Each is well-maintained
# upstream and updates on Technitium's BLOCK_LIST_UPDATE_INTERVAL_HOURS cadence.
BLOCK_LIST_URLS=(
    # Ads + trackers — broad daily-driver lists
    "https://big.oisd.nl"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"

    # Malware — abuse.ch curated, refreshed every 5 minutes upstream
    "https://urlhaus.abuse.ch/downloads/hostfile/"

    # Phishing — Phishing Army extended list
    "https://phishing.army/download/phishing_army_blocklist_extended.txt"

    # Add more here as needed. Examples:
    # "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"  # if you prefer StevenBlack over OISD
    # "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt"  # Hagezi Multi PRO
)

# ─── Blocking-engine settings (reconciled every run) ─────────────────────────────────
ENABLE_BLOCKING="true"
BLOCKING_TYPE="NxDomain"                # NxDomain | AnyAddress | CustomAddress
BLOCK_LIST_UPDATE_INTERVAL_HOURS="24"
TRIGGER_IMMEDIATE_REFRESH="${TRIGGER_IMMEDIATE_REFRESH:-true}"

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
# All helper output goes to stderr so $(get_token) and other command-substitution
# captures don't ingest log lines along with the actual return value.
log()  { printf '\033[1;34m[seed-blocklists]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found (apt install jq)"

# ─── Authentication ──────────────────────────────────────────────────────────────────
# Reuses the same token cache as seed-zones.sh (30-minute TTL).
get_token() {
    if [ -f "$TOKEN_FILE" ] && [ "$(find "$TOKEN_FILE" -mmin -30 2>/dev/null)" ]; then
        log "Reusing cached token from $TOKEN_FILE (<30 min old)"
        cat "$TOKEN_FILE"
        return 0
    fi

    [ -f "$ADMIN_PW_FILE" ] || die "Admin password file not found at $ADMIN_PW_FILE."

    local pw
    pw=$(head -n1 "$ADMIN_PW_FILE")
    [ -n "$pw" ] || die "Admin password file at $ADMIN_PW_FILE is empty."

    log "Authenticating to Technitium at $DNS_API ..."

    # Wait up to 60s for the API (in case this script is invoked during Phase-2 bring-up)
    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS "$DNS_API/api/user/login" \
            -G --data-urlencode "user=admin" --data-urlencode "pass=$pw" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    local resp
    resp=$(curl -fsS "$DNS_API/api/user/login" \
        -G --data-urlencode "user=admin" --data-urlencode "pass=$pw") \
        || die "Technitium login failed. Check the container is running and the admin password matches $ADMIN_PW_FILE."

    local status
    status=$(printf '%s' "$resp" | jq -r '.status // "unknown"')
    if [ "$status" != "ok" ]; then
        local err
        err=$(printf '%s' "$resp" | jq -r '.errorMessage // "(no message)"')
        die "Technitium login returned status=$status: $err"
    fi

    local token
    token=$(printf '%s' "$resp" | jq -r '.token // empty')
    [ -n "$token" ] || die "Login response did not contain a token. Response: $resp"

    printf '%s' "$token" > "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"
    printf '%s' "$token"
}

# ─── Main ────────────────────────────────────────────────────────────────────────────
main() {
    log "Reconciling Technitium blocking settings (${#BLOCK_LIST_URLS[@]} block list URL(s))..."

    local token
    token=$(get_token)

    # Comma-separated joined list (empirically the format Technitium parses).
    local joined
    if [ "${#BLOCK_LIST_URLS[@]}" -gt 0 ]; then
        IFS=','; joined="${BLOCK_LIST_URLS[*]}"; unset IFS
    else
        joined=""
        warn "BLOCK_LIST_URLS is empty — this will REMOVE all blocklist subscriptions."
    fi

    # Read current state for diff visibility before/after
    local before
    before=$(curl -fsS -G --data-urlencode "token=$token" "$DNS_API/api/settings/get" \
        | jq '{enableBlocking: .response.enableBlocking, blockingType: .response.blockingType, intervalHrs: .response.blockListUpdateIntervalHours, urls: .response.blockListUrls}')
    log "Before: $before"

    # Reconcile all settings in one POST
    local resp
    resp=$(curl -fsS -G \
        --data-urlencode "token=$token" \
        --data-urlencode "enableBlocking=$ENABLE_BLOCKING" \
        --data-urlencode "blockingType=$BLOCKING_TYPE" \
        --data-urlencode "blockListUpdateIntervalHours=$BLOCK_LIST_UPDATE_INTERVAL_HOURS" \
        --data-urlencode "blockListUrls=$joined" \
        "$DNS_API/api/settings/set") \
        || die "Failed to POST /api/settings/set"

    local status
    status=$(printf '%s' "$resp" | jq -r '.status // "ok"')
    if [ "$status" != "ok" ]; then
        die "Technitium reported error on settings/set: $(printf '%s' "$resp" | jq -r '.errorMessage // "(no message)"')"
    fi

    # Verify
    local after
    after=$(curl -fsS -G --data-urlencode "token=$token" "$DNS_API/api/settings/get" \
        | jq '{enableBlocking: .response.enableBlocking, blockingType: .response.blockingType, intervalHrs: .response.blockListUpdateIntervalHours, urls: .response.blockListUrls}')
    log "After:  $after"

    # Optionally trigger an immediate fetch so the new lists take effect now
    # (instead of waiting up to BLOCK_LIST_UPDATE_INTERVAL_HOURS for the next scheduled run).
    if [ "$TRIGGER_IMMEDIATE_REFRESH" = "true" ]; then
        log "Triggering immediate blocklist refresh (forceUpdateBlockLists)..."
        curl -fsS -G --data-urlencode "token=$token" \
            "$DNS_API/api/settings/forceUpdateBlockLists" > /dev/null \
            || warn "forceUpdateBlockLists failed; blocklists will refresh on the next scheduled interval (${BLOCK_LIST_UPDATE_INTERVAL_HOURS}h)."
        log "Blocklist refresh queued. Subscriptions will appear in the Technitium UI dashboard shortly."
    fi

    log "Done. Blocking is $ENABLE_BLOCKING; type=$BLOCKING_TYPE; ${#BLOCK_LIST_URLS[@]} subscription(s) declared."
    log
    log "Verify (LAN client):"
    log "  dig @192.168.10.4 doubleclick.net    # → NXDOMAIN once lists have loaded"
    log "  dig @192.168.10.4 google.com         # → still resolves"
}

main "$@"
