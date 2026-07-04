#!/usr/bin/env bash
# Heimdall — Technitium DNS zone-seeding script
#
# Purpose: declarative-flavored seeding of the .lab primary zone and its A records
# via Technitium's HTTP API. The script is **additive-only**:
#   - Creates the .lab primary zone if absent; skips if present.
#   - Adds each declared A record if absent; skips if present.
#   - NEVER deletes records, even ones not in the declaration set.
#   - NEVER overwrites existing records that don't match.
#
# Operator UI-added records persist across re-runs. This is "scriptable scaffolding,"
# not Terraform-style reconciliation. The contract is documented in
# Heimdall/docs/runbooks/phase-3-configuration.md.
#
# Punch list fixes from FINAL.md applied:
#   M3 — Uses query-string params (Technitium's actual API), NOT JSON bodies.
#        Endpoints corrected to /api/zones/create, /api/zones/records/get,
#        /api/zones/records/add. Sources Technitium admin auth from SOPS.
#
# Retry-on-5xx with exponential backoff: 3 retries, 1s/2s/4s.
# Persistent 5xx terminates non-zero, leaving zone state intact.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
DNS_API="${DNS_API:-http://127.0.0.1:5380}"
ZONE="${ZONE:-lab}"
ENV_FILE="${ENV_FILE:-/opt/Homelab/Heimdall/.env}"
ADMIN_PW_FILE="${ADMIN_PW_FILE:-/opt/Homelab/Heimdall/secrets/technitium-admin-pw}"
TOKEN_FILE="${TOKEN_FILE:-/tmp/heimdall-technitium-token}"

# ─── Record set ──────────────────────────────────────────────────────────────────────
# Format: "name|type|ipAddress[|ttl]"
# Edit this array to add/remove records the script will seed.
#
# Phase 2 minimum-viable seed: just komodo.lab so the Phase 2 end-to-end self-test
# can pass. Phase 3 grows this list.
RECORDS=(
    # ─── Hosts ───────────────────────────────────────────────────────────────
    "komodo.lab|A|192.168.10.4"       # Komodo Core UI (also fronted by Caddy)
    "heimdall.lab|A|192.168.10.4"     # edge host: Caddy, Technitium, Komodo, k3s control plane
    "auth.lab|A|192.168.10.4"         # Authentik SSO (Caddy-fronted; LDAP outpost on :389/:636)
    "akasha.lab|A|192.168.10.247"     # TrueNAS Scale (also hosts Jellyfin :30013)
    "thoth.lab|A|192.168.10.144"      # GPU compute host (Ollama, Tdarr worker, Wings)
    "ollama.lab|A|192.168.10.4"       # Ollama on Thoth, fronted by Caddy
    "openwebui.lab|A|192.168.10.4"    # OpenWebUI (chat for Ollama) on Thoth, via Caddy
    "comfyui.lab|A|192.168.10.4"      # ComfyUI (image gen) on Thoth, via Caddy
    "jellyfin.lab|A|192.168.10.247"   # alias for Akasha; Jellyfin UI is at :30013 (NodePort)

    # ─── Hyperion k3s nodes (.101..110, Greek-letter order) ──────────────────
    "hyperion-alpha.lab|A|192.168.10.101"
    "hyperion-beta.lab|A|192.168.10.102"
    "hyperion-gamma.lab|A|192.168.10.103"
    "hyperion-delta.lab|A|192.168.10.104"
    "hyperion-epsilon.lab|A|192.168.10.105"
    "hyperion-zeta.lab|A|192.168.10.106"
    "hyperion-eta.lab|A|192.168.10.107"
    "hyperion-theta.lab|A|192.168.10.108"
    "hyperion-iota.lab|A|192.168.10.109"
    "hyperion-kappa.lab|A|192.168.10.110"

    # ─── Apps (MetalLB LoadBalancer IPs) ─────────────────────────────────────
    # NOTE: DNS resolves name->IP only; the service port is NOT encoded. Append
    # the port shown below (e.g. http://beszel.lab:8090). To get portless
    # https://<app>.lab you'd add Caddy reverse-proxy routes — out of scope here.
    "beszel.lab|A|192.168.10.68"          # :8090  (monitoring — "Bes")
    "headlamp.lab|A|192.168.10.50"        # :80    (k8s dashboard)
    "hermes.lab|A|192.168.10.52"          # :80    (DeepSeek AI, basic-auth)
    "pterodactyl.lab|A|192.168.10.69"     # :80    (game-server panel)
    "speedtest.lab|A|192.168.10.67"       # :80    (speedtest-tracker)
    "uptime.lab|A|192.168.10.51"          # :80    (uptime-kuma)
    "homarr.lab|A|192.168.10.53"          # :7575  (dashboard)
    "homeassistant.lab|A|192.168.10.4"    # Home Assistant smart home (Caddy → 192.168.10.147:8123)
    "seerr.lab|A|192.168.10.54"           # :5055  (media requests)
    "prowlarr.lab|A|192.168.10.55"        # :9696  (indexer manager)
    "sonarr.lab|A|192.168.10.56"          # :8989  (TV)
    "radarr.lab|A|192.168.10.57"          # :7878  (movies)
    "qbittorrent.lab|A|192.168.10.58"     # :8085  (downloads)
    "qbittorrent-b.lab|A|192.168.10.83"   # :8085  (downloads — 2nd qbittorrent+gluetun instance, Seattle VPN)
    "qbittorrent-c.lab|A|192.168.10.84"   # :8085  (downloads — 3rd qbittorrent+gluetun instance, Los Angeles VPN)
    "cleanuparr.lab|A|192.168.10.59"      # :11011 (download cleanup)
    "kapowarr.lab|A|192.168.10.60"        # :5656  (comics/manga)
    "youtarr.lab|A|192.168.10.61"         # :3087  (youtube archival)
    "tdarr.lab|A|192.168.10.62"           # :8265  (transcoding)
    "trailarr.lab|A|192.168.10.63"        # :7889  (trailers)
    "suggestarr.lab|A|192.168.10.64"      # :5000  (content suggestions)
    "lidarr.lab|A|192.168.10.65"          # :8686  (music)
    "navidrome.lab|A|192.168.10.66"       # :4533  (music streaming)
    "caldera.lab|A|192.168.10.70"         # :8000  (Obsidian vault REST API for AI agents)
    "n8n.lab|A|192.168.10.71"             # :5678  (workflow automation)
    "mqtt.lab|A|192.168.10.72"            # :1883  (Mosquitto MQTT broker)
    "listenarr.lab|A|192.168.10.73"      # :4545  (audiobook manager)
    "musicseerr.lab|A|192.168.10.74"     # :8688  (music requests via Lidarr)
    "boxarr.lab|A|192.168.10.75"         # :8888  (box office → Radarr)
    "jellystat.lab|A|192.168.10.76"      # :3000  (Jellyfin statistics)
    "sortarr.lab|A|192.168.10.77"        # :8787  (media library analytics)
    "romm.lab|A|192.168.10.78"          # :8080  (ROM manager)
    "monolithbot.lab|A|192.168.10.79"   # :80    (Discord bot admin UI)
    "mqttexplorer.lab|A|192.168.10.81"  # :80    (MQTT Explorer web UI)
    "nextcloud.lab|A|192.168.10.87"       # :80    (NextCloud — moved off .82 which komga took)
    "asf.lab|A|192.168.10.86"             # :1242  (ArchiSteamFarm — Steam card farmer)
    # ── Backfilled 2026-07-04 (were operator-UI-added / missing from git) ──
    "komga.lab|A|192.168.10.82"           # :25600 (comic/manga server — holds .82)
    "agent-caldera.lab|A|192.168.10.85"   # :8000  (agent shared-knowledge Caldera)
    "guppi.lab|A|192.168.10.52"           # :80    (Hermes/Guppi AI agent)
    "jeeves.lab|A|192.168.10.80"          # :80    (Jeeves AI agent)
    "uptime-kuma.lab|A|192.168.10.51"     # :80    (alias for uptime.lab)
    "pihole.lab|A|192.168.10.4"           # :80    (Pi-hole admin, Caddy-fronted)
    "technitium.lab|A|192.168.10.4"       # :5380  (Technitium admin, Caddy-fronted)
    "truenas.lab|A|192.168.10.247"        # alias for akasha.lab (TrueNAS)
)

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
# All helper output goes to stderr so $(get_token) and other command-substitution
# captures don't ingest log lines along with the actual return value.
log()  { printf '\033[1;34m[seed]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found (apt install jq)"

# ─── Retry wrapper ───────────────────────────────────────────────────────────────────
# Usage: retry_curl <description> <curl-args...>
# Returns the response body on success; dies on persistent failure.
retry_curl() {
    local desc=$1; shift
    local sleep_for=1
    local attempts=3
    local resp
    local code

    for attempt in $(seq 1 "$attempts"); do
        if resp=$(curl -fsS -w '\n___HTTPCODE___%{http_code}' "$@" 2>/dev/null); then
            code="${resp##*___HTTPCODE___}"
            resp="${resp%___HTTPCODE___*}"
            resp="${resp%$'\n'}"

            if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
                # Technitium returns 200 even for some logical errors; parse the body for status.
                local status
                status=$(printf '%s' "$resp" | jq -r '.status // empty' 2>/dev/null || true)
                if [ "$status" = "error" ]; then
                    local errmsg
                    errmsg=$(printf '%s' "$resp" | jq -r '.errorMessage // "unknown error"')
                    warn "$desc: Technitium reported error: $errmsg"
                    # Don't retry on logical errors — they won't fix themselves.
                    printf '%s' "$resp"
                    return 1
                fi
                printf '%s' "$resp"
                return 0
            elif [[ "$code" =~ ^5[0-9][0-9]$ ]] && [ "$attempt" -lt "$attempts" ]; then
                warn "$desc: HTTP $code (attempt $attempt/$attempts), retrying in ${sleep_for}s"
                sleep "$sleep_for"
                sleep_for=$(( sleep_for * 2 ))
                continue
            else
                warn "$desc: HTTP $code; body: $resp"
                return 1
            fi
        else
            # curl itself failed (connection refused, etc.)
            if [ "$attempt" -lt "$attempts" ]; then
                warn "$desc: curl failed (attempt $attempt/$attempts), retrying in ${sleep_for}s"
                sleep "$sleep_for"
                sleep_for=$(( sleep_for * 2 ))
            else
                return 1
            fi
        fi
    done
    return 1
}

# ─── Authentication ──────────────────────────────────────────────────────────────────
get_token() {
    # Cache token across runs of this script (Technitium tokens are session-scoped).
    if [ -f "$TOKEN_FILE" ] && [ "$(find "$TOKEN_FILE" -mmin -30 2>/dev/null)" ]; then
        log "Reusing cached token from $TOKEN_FILE (<30 min old)"
        cat "$TOKEN_FILE"
        return 0
    fi

    [ -f "$ADMIN_PW_FILE" ] || die "Admin password file not found at $ADMIN_PW_FILE. Decrypt secrets/technitium-admin-pw.sops first."

    local pw
    pw=$(head -n1 "$ADMIN_PW_FILE")
    [ -n "$pw" ] || die "Admin password file at $ADMIN_PW_FILE is empty."

    log "Authenticating to Technitium at $DNS_API ..."

    # Wait for Technitium API to be ready (Phase 2 may invoke this script while the
    # container is still starting). 60s budget.
    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS "$DNS_API/api/user/login" \
            -G --data-urlencode "user=admin" --data-urlencode "pass=$pw" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    local login_resp
    login_resp=$(curl -fsS "$DNS_API/api/user/login" \
        -G --data-urlencode "user=admin" --data-urlencode "pass=$pw") \
        || die "Technitium login failed. Check the container is running and the admin password matches secrets/technitium-admin-pw."

    local token
    token=$(printf '%s' "$login_resp" | jq -r '.token // empty')
    if [ -z "$token" ]; then
        die "Login response did not contain a token. Response: $login_resp"
    fi

    printf '%s' "$token" > "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"
    printf '%s' "$token"
}

# ─── Zone idempotence ────────────────────────────────────────────────────────────────
zone_exists() {
    local token=$1
    local zone=$2
    local resp
    resp=$(curl -fsS "$DNS_API/api/zones/list" \
        -G --data-urlencode "token=$token" 2>/dev/null) || return 1
    printf '%s' "$resp" | jq -e --arg z "$zone" '.response.zones[]? | select(.name == $z)' >/dev/null 2>&1
}

create_zone() {
    local token=$1
    local zone=$2

    if zone_exists "$token" "$zone"; then
        log "Zone '$zone' already exists; skipping create."
        return 0
    fi

    log "Creating primary zone '$zone' ..."
    retry_curl "create_zone($zone)" \
        -X POST "$DNS_API/api/zones/create" \
        -G --data-urlencode "token=$token" \
              --data-urlencode "zone=$zone" \
              --data-urlencode "type=Primary" \
        >/dev/null \
        || die "Failed to create zone '$zone'"
    log "Zone '$zone' created."
}

# ─── Record idempotence ──────────────────────────────────────────────────────────────
record_matches() {
    # Returns 0 if a record with this name+type+rdata already exists.
    local token=$1
    local zone=$2
    local domain=$3
    local rtype=$4
    local rdata=$5

    local resp
    resp=$(curl -fsS "$DNS_API/api/zones/records/get" \
        -G --data-urlencode "token=$token" \
              --data-urlencode "zone=$zone" \
              --data-urlencode "domain=$domain" \
              --data-urlencode "listZone=false" 2>/dev/null) || return 1

    # Filter for exact name+type+rdata match. Technitium's record-list shape:
    #   .response.records[] | { name, type, rData: { ipAddress, ... } }
    printf '%s' "$resp" | jq -e --arg n "$domain" --arg t "$rtype" --arg d "$rdata" \
        '.response.records[]? | select(.name == $n and .type == $t and (.rData.ipAddress == $d or .rData.nameServer == $d or .rData.cname == $d))' \
        >/dev/null 2>&1
}

add_record() {
    local token=$1
    local zone=$2
    local domain=$3
    local rtype=$4
    local rdata=$5
    local ttl=${6:-3600}

    if record_matches "$token" "$zone" "$domain" "$rtype" "$rdata"; then
        log "Record $domain ($rtype $rdata) already present; skipping."
        return 0
    fi

    log "Adding record: $domain ($rtype $rdata, ttl=$ttl)"

    # The exact ipAddress/cname/etc. param name depends on the record type.
    # For A records: ipAddress
    # For CNAME:     cname
    # For AAAA:      ipAddress (Technitium uses the same param for v4 and v6)
    # See Technitium APIDOCS.md /api/zones/records/add for the full type→param map.
    local rdata_param
    case "$rtype" in
        A|AAAA) rdata_param="ipAddress" ;;
        CNAME)  rdata_param="cname"     ;;
        NS)     rdata_param="nameServer" ;;
        *)      die "Unsupported record type '$rtype' in seed list. Extend the case statement." ;;
    esac

    retry_curl "add_record($domain $rtype $rdata)" \
        -X POST "$DNS_API/api/zones/records/add" \
        -G --data-urlencode "token=$token" \
              --data-urlencode "zone=$zone" \
              --data-urlencode "domain=$domain" \
              --data-urlencode "type=$rtype" \
              --data-urlencode "$rdata_param=$rdata" \
              --data-urlencode "ttl=$ttl" \
              --data-urlencode "overwrite=false" \
        >/dev/null \
        || die "Failed to add record $domain ($rtype $rdata)"
}

# ─── Recursion / upstream forwarders ─────────────────────────────────────────────────
# Technitium is authoritative for .lab but ships with recursion=Deny /
# forwarders=None. Since Pi-hole uses Technitium as its sole upstream, without
# this the whole homelab loses EXTERNAL DNS (github.com etc. return REFUSED).
# Captured as code after the 2026-07-04 outage. Idempotent (set is a no-op if
# already correct).
set_forwarders() {
    local token=$1
    log "Ensuring Technitium recursion=AllowOnlyForPrivateNetworks + forwarders=1.1.1.1,8.8.8.8"
    retry_curl "set_forwarders" \
        -X POST "$DNS_API/api/settings/set" \
        -G --data-urlencode "token=$token" \
              --data-urlencode "recursion=AllowOnlyForPrivateNetworks" \
              --data-urlencode "forwarders=1.1.1.1, 8.8.8.8" \
              --data-urlencode "forwarderProtocol=Udp" \
        >/dev/null \
        || die "Failed to set Technitium forwarders/recursion"
}

# ─── Main ────────────────────────────────────────────────────────────────────────────
main() {
    log "Seeding Technitium zone '$ZONE' with ${#RECORDS[@]} record(s)."

    local token
    token=$(get_token)

    create_zone "$token" "$ZONE"
    set_forwarders "$token"

    for rec in "${RECORDS[@]}"; do
        # Parse "name|type|rdata[|ttl]"
        IFS='|' read -r name rtype rdata ttl <<< "$rec"
        add_record "$token" "$ZONE" "$name" "$rtype" "$rdata" "${ttl:-3600}"
    done

    log "Seed complete. Zone '$ZONE' has ${#RECORDS[@]} declared record(s) (operator UI-added records persist)."
    log
    log "Verify:"
    log "  dig @192.168.10.4 ${RECORDS[0]%%|*}"
    log "  curl -G --data-urlencode 'token=\$TOKEN' --data-urlencode 'zone=$ZONE' --data-urlencode 'listZone=true' $DNS_API/api/zones/records/get | jq"
}

main "$@"
