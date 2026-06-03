#!/usr/bin/env bash
# Heimdall — Phase 1 host setup
#
# Idempotent. Each step has a precondition guard so re-running on a partially-configured
# host is safe. Markers under /var/lib/heimdall-setup/<step>.done record completion.
# Invoke `setup.sh --force <step>` to wipe a marker and re-run that step.
#
# Run on a fresh Ubuntu Server 26.04 LTS install. Operator workflow:
#   curl -O https://raw.githubusercontent.com/StevenGann/Homelab/main/Heimdall/scripts/setup.sh
#   less setup.sh                          # audit before running (iter-1 known concern #12)
#   sudo bash setup.sh
#
# Then proceed to Phase 2 (see Heimdall/docs/runbooks/phase-2-containers.md).

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────────────
REPO_DIR="${REPO_DIR:-/opt/Homelab}"
REPO_URL="${REPO_URL:-https://github.com/StevenGann/Homelab.git}"
HEIMDALL_DIR="${REPO_DIR}/Heimdall"
MARKER_DIR="/var/lib/heimdall-setup"
PERIPHERY_VERSION="${PERIPHERY_VERSION:-v2.2.0}"

# ─── Helpers ─────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root (sudo bash setup.sh)."
}

step_done() {
    [ -f "${MARKER_DIR}/$1.done" ]
}

mark_step() {
    mkdir -p "$MARKER_DIR"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${MARKER_DIR}/$1.done"
}

force_step() {
    rm -f "${MARKER_DIR}/$1.done"
}

# ─── Argument parsing ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--force" ] && [ -n "${2:-}" ]; then
    force_step "$2"
    log "Forced re-run of step: $2"
fi

require_root

# ─── Step 01 — base packages + Docker CE upstream repo ──────────────────────────────
step_01_apt_docker() {
    log "Installing base packages + Docker CE upstream repo..."

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg jq \
        nftables chrony systemd-journal-remote unattended-upgrades \
        age git python3 python3-pip

    # Docker CE keyring (hash-compare before re-write to avoid pointless changes)
    install -m 0755 -d /etc/apt/keyrings
    KEYRING=/etc/apt/keyrings/docker.asc
    KEYRING_TMP=$(mktemp)
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$KEYRING_TMP"
    if [ ! -f "$KEYRING" ] || ! cmp -s "$KEYRING_TMP" "$KEYRING"; then
        mv "$KEYRING_TMP" "$KEYRING"
        chmod a+r "$KEYRING"
        log "Docker keyring updated."
    else
        rm -f "$KEYRING_TMP"
    fi

    SRC=/etc/apt/sources.list.d/docker.list
    SRC_LINE="deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable"
    if [ ! -f "$SRC" ] || ! grep -qF "$SRC_LINE" "$SRC"; then
        echo "$SRC_LINE" > "$SRC"
        log "Docker apt source updated."
        apt-get update -qq
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # Add `owner` to the docker group so `docker` commands work without sudo.
    # Idempotent — usermod -aG is a no-op if owner is already a member.
    # The group membership takes effect on the next login (SSH session, sudo -i, etc.).
    if id owner >/dev/null 2>&1; then
        usermod -aG docker owner
    else
        warn "User 'owner' does not exist yet; skipping docker group membership."
        warn "After creating 'owner', run: sudo usermod -aG docker owner"
    fi

    # sops is not always packaged; install via direct download from the upstream release
    # if `apt install sops` is not available. (Ubuntu 26.04's `getsops` package, if shipped,
    # provides this; fall back to download.)
    if ! command -v sops >/dev/null 2>&1; then
        if apt-cache show sops >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sops
        else
            warn "apt has no sops package; install manually from github.com/getsops/sops/releases"
        fi
    fi

    mark_step 01_apt_docker
}

# ─── Step 02 — netplan static IP ─────────────────────────────────────────────────────
# After applying, the static address must actually be present on the host — both
# netplan apply and netplan try return 0 in some cases where the config fails to
# bind to an interface (e.g., ambiguous match). We verify post-apply that the
# expected IP is on a real interface before marking the step done.
step_02_netplan() {
    log "Installing netplan config..."

    # Guard against the placeholder MAC. The committed netplan ships with
    # "TODO-FILL-IN-MAC-OF-UPLINK-NIC" so the operator can't accidentally apply
    # an unconfigured file.
    if grep -q "TODO-FILL-IN-MAC-OF-UPLINK-NIC" "${HEIMDALL_DIR}/netplan/01-uplink.yaml"; then
        die "netplan template still has the MAC placeholder. Edit ${HEIMDALL_DIR}/netplan/01-uplink.yaml — replace TODO-FILL-IN-MAC-OF-UPLINK-NIC with the MAC of the uplink NIC (see ethtool output)."
    fi

    install -m 0600 -o root -g root \
        "${HEIMDALL_DIR}/netplan/01-uplink.yaml" \
        /etc/netplan/01-uplink.yaml

    # `netplan try` reverts after 120s if SSH dies — safer than `netplan apply` on a remote host.
    # For first-run on a fresh install, the operator may be at the console; `apply` is fine then.
    # Detect TTY: if running interactively over SSH, prefer `try`.
    if [ -t 0 ] && [ -n "${SSH_CONNECTION:-}" ]; then
        log "Running netplan try (auto-reverts in 120s if SSH dies)..."
        netplan try --timeout 120 || die "netplan try failed; check syntax in /etc/netplan/01-uplink.yaml"
    else
        netplan apply
    fi

    # Verify the static IP actually landed on a real interface. netplan can exit 0
    # while the config silently fails to apply (e.g., no NIC matches by name/MAC).
    EXPECTED_IP="192.168.10.4"
    if ! ip -4 addr show 2>/dev/null | grep -q "inet ${EXPECTED_IP}/"; then
        warn "netplan exited 0 but ${EXPECTED_IP} is NOT assigned to any interface."
        warn "Likely causes: NIC MAC in ${HEIMDALL_DIR}/netplan/01-uplink.yaml doesn't match any installed NIC,"
        warn "or the matched NIC has no link. Diagnose with:"
        warn "  ip -br link"
        warn "  sudo ethtool <iface> | grep -E 'Link detected|Speed'"
        die "netplan apply did not produce the expected address; aborting before marking step done."
    fi

    log "Static IP ${EXPECTED_IP} confirmed on a live interface."
    mark_step 02_netplan
}

# ─── Step 03 — systemd-resolved drop-in + resolv.conf symlink swap ───────────────────
# Order matters: write drop-in → restart resolved → swap symlink.
# Doing them in any other order leaves the host with a stale resolv.conf pointing at 127.0.0.53
# which has been disabled (DNSStubListener=no), so the host loses DNS until next step completes.
step_03_resolved() {
    log "Configuring systemd-resolved (DNSStubListener=no)..."

    install -d -m 0755 /etc/systemd/resolved.conf.d
    install -m 0644 \
        "${HEIMDALL_DIR}/hostconf/resolved-no-stub.conf" \
        /etc/systemd/resolved.conf.d/no-stub.conf

    systemctl restart systemd-resolved

    # Swap /etc/resolv.conf to the upstream-direct view, not the stub.
    # On stock Ubuntu this is initially a symlink to ../run/systemd/resolve/stub-resolv.conf.
    if [ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/resolv.conf" ]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        log "/etc/resolv.conf now points at the upstream view."
    fi

    mark_step 03_resolved
}

# ─── Step 04 — nftables ruleset ──────────────────────────────────────────────────────
step_04_nftables() {
    log "Loading nftables ruleset..."

    install -m 0644 \
        "${HEIMDALL_DIR}/hostconf/nftables.conf" \
        /etc/nftables.conf

    # Do NOT `nft flush ruleset` here. A global flush also wipes Docker's
    # iptables-nft NAT tables, un-publishing the bridge-networked k3s control
    # plane (:6443) and taking every Hyperion worker NotReady — only
    # `systemctl restart docker` recovers it (caused a cluster outage 2026-06-03).
    # The committed nftables.conf does its own table-scoped reset (declare+delete
    # `table inet heimdall_fw`), so `nft -f` is idempotent and Docker-safe on
    # re-runs — including a forced re-run of this step. Completes the 89f4bd7 fix
    # (which patched nftables.conf but left this global flush in place).
    nft -f /etc/nftables.conf

    systemctl enable --now nftables.service

    mark_step 04_nftables
}

# ─── Step 05 — systemd-journal-upload to Akasha ────────────────────────────────────
step_05_journal_upload() {
    log "Configuring systemd-journal-upload..."

    install -d -m 0755 /etc/systemd/journal-upload.conf.d
    install -m 0644 \
        "${HEIMDALL_DIR}/hostconf/journal-upload-akasha.conf" \
        /etc/systemd/journal-upload.conf.d/akasha.conf

    # Persistent local journal (so we have local buffering when Akasha is unreachable).
    install -d -m 0755 /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald

    # Cap journald local storage so a long Akasha outage doesn't fill the disk.
    install -d -m 0755 /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/limit.conf <<'EOF'
[Journal]
SystemMaxUse=2G
EOF

    systemctl enable --now systemd-journal-upload.service

    mark_step 05_journal_upload
}

# ─── Step 06 — Docker daemon config ──────────────────────────────────────────────────
step_06_docker_daemon() {
    log "Configuring Docker daemon..."

    install -d -m 0755 /etc/docker

    NEW=/etc/docker/daemon.json
    TMP=$(mktemp)
    cp "${HEIMDALL_DIR}/hostconf/docker-daemon.json" "$TMP"

    if [ ! -f "$NEW" ] || ! cmp -s "$TMP" "$NEW"; then
        install -m 0644 "$TMP" "$NEW"
        log "Restarting docker (daemon.json changed)..."
        systemctl restart docker
    else
        log "daemon.json unchanged; skipping docker restart."
    fi
    rm -f "$TMP"

    systemctl enable docker

    mark_step 06_docker_daemon
}

# ─── Step 07 — Repo clone ────────────────────────────────────────────────────────────
step_07_repo() {
    if [ -d "${REPO_DIR}/.git" ]; then
        log "Repo already cloned at ${REPO_DIR}; skipping."
    else
        log "Cloning repo to ${REPO_DIR}..."
        git clone "$REPO_URL" "$REPO_DIR"
    fi

    # Set ownership so the `owner` user can edit without sudo.
    if id owner >/dev/null 2>&1; then
        chown -R owner:owner "$REPO_DIR"
    else
        warn "User 'owner' does not exist; leaving repo owned by root."
    fi

    mark_step 07_repo
}

# ─── Step 08 — Komodo Periphery (systemd binary, not container) ──────────────────────
step_08_periphery() {
    log "Installing Komodo Periphery..."

    if [ -x /usr/local/bin/periphery ]; then
        log "Periphery binary already present; will not re-download."
    else
        # Two-step audit pattern (iter-1 known concern #12): download → audit → run.
        # On a first-time setup.sh invocation we run the script directly, but the operator
        # should have already audited setup.sh itself. The Periphery installer script's
        # contents are documented at github.com/moghtech/komodo/scripts/setup-periphery.py.
        TMP_SCRIPT=$(mktemp --suffix=.py)
        curl -fsSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py -o "$TMP_SCRIPT"
        python3 "$TMP_SCRIPT" --version "$PERIPHERY_VERSION"
        rm -f "$TMP_SCRIPT"
    fi

    # The upstream installer only `systemctl start`s — NOT enable. Make Periphery
    # survive reboots (FC new fact B from the pipeline run).
    systemctl enable --now periphery.service

    # Confirm Periphery is listening on :8120. Periphery takes 1-2s to initialize on
    # first start (key generation + SSL cert generation); poll up to 15s before warning.
    # The default config binds [::]:8120 with TLS enabled; nftables enforces 127.0.0.0/8
    # source restriction on :8120 so external access is denied.
    log "Waiting for Periphery to bind :8120..."
    for i in $(seq 1 15); do
        if ss -tlnp 2>/dev/null | grep -q ':8120'; then
            log "Periphery listening on :8120 after ${i}s."
            break
        fi
        sleep 1
    done
    if ! ss -tlnp 2>/dev/null | grep -q ':8120'; then
        warn "Periphery did not bind :8120 within 15s. Check 'journalctl -u periphery -n 50'."
    fi

    mark_step 08_periphery
}

# ─── Step 09 — chrony time sync ──────────────────────────────────────────────────────
step_09_chrony() {
    log "Configuring chrony..."

    # Use UCG as primary NTP source; public pool as fallback.
    cat > /etc/chrony/conf.d/heimdall.conf <<'EOF'
pool 192.168.10.1 iburst maxsources 1
pool pool.ntp.org iburst maxsources 4
EOF

    systemctl enable --now chrony.service
    systemctl restart chrony.service

    mark_step 09_chrony
}

# ─── Step 10 — unattended-upgrades ───────────────────────────────────────────────────
step_10_unattended() {
    log "Configuring unattended-upgrades..."

    # Allow the Docker upstream repo for security updates.
    cat > /etc/apt/apt.conf.d/52heimdall-unattended <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "site=download.docker.com";
};

// Kernel-reboot-only on Sundays at 04:00 if /var/run/reboot-required is present.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Hold-back: never auto-bump Docker major versions or kernel hwe meta-packages.
// (Apt does not have a true major-version hold; this is documentation-as-config.)
EOF

    systemctl enable --now unattended-upgrades.service

    mark_step 10_unattended
}

# ─── Main ────────────────────────────────────────────────────────────────────────────
main() {
    log "Heimdall Phase 1 host setup beginning..."
    log "Marker dir: $MARKER_DIR"

    # Order is important: nftables/journal/docker need the apt step; netplan should
    # land before the network-sensitive steps; resolved comes before docker so
    # `docker pull` works in step 06 when daemon restarts.
    step_done 01_apt_docker        || step_01_apt_docker
    step_done 07_repo              || step_07_repo            # before steps that read $HEIMDALL_DIR/...
    step_done 02_netplan           || step_02_netplan
    step_done 03_resolved          || step_03_resolved
    step_done 04_nftables          || step_04_nftables
    step_done 05_journal_upload    || step_05_journal_upload
    step_done 06_docker_daemon     || step_06_docker_daemon
    step_done 09_chrony            || step_09_chrony
    step_done 10_unattended        || step_10_unattended
    step_done 08_periphery         || step_08_periphery

    log "Phase 1 complete."
    log
    log "Verify:"
    log "  systemctl is-active periphery.service nftables systemd-journal-upload chrony docker"
    log "  ss -tlnp | grep 8120                # Periphery listening"
    log "  nft list ruleset | head -40         # nftables loaded"
    log "  resolvectl status | grep -A1 stub   # DNSStubListener=no"
    log
    log "Next:"
    log "  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \\"
    log "    sops --decrypt ${HEIMDALL_DIR}/secrets/env.sops.yaml > ${HEIMDALL_DIR}/.env"
    log "  cd ${HEIMDALL_DIR} && docker compose pull && docker compose up -d"
    log "  bash ${HEIMDALL_DIR}/scripts/onboard-periphery.sh"
    log "  bash ${HEIMDALL_DIR}/scripts/seed-zones.sh"
}

main "$@"
