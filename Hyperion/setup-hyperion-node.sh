#!/usr/bin/env bash
# setup-hyperion-node.sh
#
# TURNKEY: take ONE Hyperion Pi 5 from a stock Raspberry-Pi-OS bootstrap SD all
# the way to a NixOS worker on the NVMe that has joined the Heimdall k3s control
# plane — driven entirely over SSH from the workstation. The ONLY hands-on step
# is physically inserting the (single, reused) bootstrap SD and powering the node.
#
# Validated end-to-end on hyperion-alpha 2026-06-01 (first NixOS worker Ready).
#
#   ./setup-hyperion-node.sh --name hyperion-alpha --ip 192.168.10.101
#   ./setup-hyperion-node.sh --name hyperion-beta              # IP from inventory.yaml
#
# PREREQUISITES (per node):
#   - The node is powered on with the stock RasPi-OS bootstrap SD inserted and
#     SSH enabled (default user 'pi', default password 'raspberry'), reachable
#     at --ip. NVMe is a SEPARATE blank/old disk (we install onto it).
#   - Run from the workstation on the 192.168.10.0/24 VLAN with the operator
#     age key at ~/.config/sops/age/keys.txt and: age, sops, ssh-keygen,
#     rsync, python3 on PATH. (No Nix needed on the workstation — the closure
#     builds/substitutes on the node.)
#
# WHY THIS SHAPE (see docs/runbooks/turnkey-node-setup.md + ADR-0001):
#   - kexec is dead on these Pis (/proc/kcore absent), so nixos-anywhere's
#     default flow can't run. But the NVMe is a SEPARATE disk from the SD we're
#     booted on, so there is no same-disk chicken-and-egg: we install onto the
#     NVMe from the running bootstrap with disko-install. No NixOS-installer SD.
#   - disko-install's offline activation aborts on a sops-nix `mount` call that
#     isn't on PATH; we finish the bootloader install via nixos-enter with
#     util-linux on PATH. Both wrinkles are handled below.
#
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%T')]${NC} $*"; }
step() { echo -e "\n${CYAN}━━ $* ━━${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%T')] WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}[$(date '+%T')] ERROR:${NC} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
INVENTORY="${REPO_ROOT}/inventory.yaml"

# ── Tunables (env-overridable) ──────────────────────────────────────────────
BOOTSTRAP_USER="${BOOTSTRAP_USER:-pi}"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-raspberry}"   # stock RasPi-OS default
TARGET_USER="owner"                                     # the NixOS login user
BOOT_ORDER="${BOOT_ORDER:-0xf416}"                      # NVMe -> SD -> USB -> loop
CACHIX_SUB="https://nixos-raspberrypi.cachix.org"
CACHIX_KEY="nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
NIX="/nix/var/nix/profiles/default/bin/nix"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

NAME=""; IP=""; ASSUME_YES=0
usage() {
    cat <<EOF
Usage: $0 --name hyperion-<greek> [--ip <addr>] [--yes]

  --name   Target hostname; must match nixos/hosts/<name>.nix
  --ip     Node IP (the RasPi-OS bootstrap address). If omitted, looked up in
           inventory.yaml.
  --yes    Skip the destructive-wipe confirmation.

Env overrides: BOOTSTRAP_USER, BOOTSTRAP_PASSWORD, BOOT_ORDER, SOPS_AGE_KEY_FILE
EOF
    exit 1
}
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --ip)   IP="$2"; shift 2 ;;
        --yes)  ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

# ── Phase 0: preflight ──────────────────────────────────────────────────────
step "Phase 0 — preflight"
[ -n "$NAME" ] || usage
[[ "$NAME" =~ ^hyperion-[a-z]+$ ]] || die "Name must match hyperion-<greek> (got: $NAME)"
[ -f "${FLAKE_DIR}/hosts/${NAME}.nix" ] || die "No host config at nixos/hosts/${NAME}.nix"

if [ -z "$IP" ]; then
    [ -f "$INVENTORY" ] || die "No --ip and no inventory.yaml to look it up in"
    IP="$(awk -v n="$NAME" '$0 ~ "name:[[:space:]]*"n {for(i=1;i<=NF;i++) if($i=="ip:"){print $(i+1); exit}}' "$INVENTORY" | tr -d ',}')"
    [ -n "$IP" ] || die "Could not find IP for $NAME in $INVENTORY"
    log "Resolved $NAME -> $IP from inventory.yaml"
fi
[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Bad IP: $IP"

for t in age sops ssh-keygen rsync python3 ssh; do command -v "$t" >/dev/null || die "$t not on PATH"; done
[ -f "$SOPS_AGE_KEY_FILE" ] || die "Operator age key not found at $SOPS_AGE_KEY_FILE"
ping -c1 -W2 "$IP" >/dev/null 2>&1 || die "$IP not reachable (is the node powered + on the .10 VLAN?)"
log "Target: ${CYAN}${NAME}${NC} @ ${CYAN}${IP}${NC}   bootstrap user: ${BOOTSTRAP_USER}"

PUBKEY="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null)"
[ -n "$PUBKEY" ] || PUBKEY="$(cat ~/.ssh/*.pub 2>/dev/null | head -1)"
[ -n "$PUBKEY" ] || die "No workstation SSH pubkey in ~/.ssh/*.pub"

SSH_K="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 ${BOOTSTRAP_USER}@${IP}"

# ── Phase 1: bootstrap access (key + passwordless sudo) ─────────────────────
step "Phase 1 — bootstrap access (key + NOPASSWD sudo as ${BOOTSTRAP_USER})"
if $SSH_K true 2>/dev/null; then
    log "Key auth already works — skipping password bootstrap."
else
    log "Installing workstation key + NOPASSWD sudo via password auth..."
    PTY_HELPER="$(mktemp)"; trap 'rm -f "$PTY_HELPER"' EXIT
    cat > "$PTY_HELPER" <<'PYEOF'
import os, pty, sys, select, time
host, user, password, cmd = sys.argv[1:5]
argv = ["ssh","-o","StrictHostKeyChecking=accept-new","-o","PreferredAuthentications=password",
        "-o","PubkeyAuthentication=no","-o","ConnectTimeout=10","-o","NumberOfPasswordPrompts=1",
        f"{user}@{host}", cmd]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("ssh", argv); os._exit(127)
buf=b""; sent=False; deadline=time.time()+45
while time.time()<deadline:
    r,_,_ = select.select([fd],[],[],1.0)
    if fd in r:
        try: data=os.read(fd,4096)
        except OSError: break
        if not data: break
        buf+=data; sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
        if not sent and b"assword" in buf:
            os.write(fd,(password+"\n").encode()); sent=True
    try:
        wpid,st = os.waitpid(pid, os.WNOHANG)
        if wpid==pid: sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
    except ChildProcessError: break
PYEOF
    RCMD="mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo '$BOOTSTRAP_PASSWORD' | sudo -S sh -c 'echo \"$BOOTSTRAP_USER ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/010-hyperion-nopasswd && chmod 440 /etc/sudoers.d/010-hyperion-nopasswd' 2>/dev/null; echo BOOTSTRAP_DONE"
    python3 "$PTY_HELPER" "$IP" "$BOOTSTRAP_USER" "$BOOTSTRAP_PASSWORD" "$RCMD" 2>&1 | grep -q BOOTSTRAP_DONE \
        || die "Password bootstrap failed (wrong BOOTSTRAP_PASSWORD?)"
    $SSH_K 'sudo -n true' 2>/dev/null && log "  key + NOPASSWD sudo confirmed." || die "Key/sudo bootstrap did not take"
fi

# Sanity: we must be on the SD bootstrap (root on mmc), with a separate NVMe.
ROOT_SRC="$($SSH_K 'findmnt -nro SOURCE /')"
case "$ROOT_SRC" in
    /dev/nvme0n1*) die "Root is on the NVMe — this is not a bootstrap node. Refusing." ;;
esac
$SSH_K 'test -b /dev/nvme0n1' || die "No /dev/nvme0n1 on $NAME — nothing to install onto."
log "Bootstrap OK: root on ${ROOT_SRC}, target /dev/nvme0n1 present."

# ── Phase 2: register node key (idempotent) ─────────────────────────────────
step "Phase 2 — register per-node keys + re-encrypt secrets"
if [ -f "${FLAKE_DIR}/node-keys/${NAME}.tar.age" ]; then
    log "Key bundle already exists for ${NAME} — skipping registration."
else
    SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" "${REPO_ROOT}/register-node-key.sh" "$NAME" \
        || die "register-node-key.sh failed"
fi

# ── Phase 3: prep the node (Nix + substituters + flake + secret tree) ───────
step "Phase 3 — prepare bootstrap (Nix, caches, flake, secrets)"
if ! $SSH_K "test -x $NIX"; then
    log "Installing Determinate Nix on the bootstrap..."
    $SSH_K 'curl --proto "=https" --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sudo sh -s -- install linux --no-confirm' \
        >/dev/null 2>&1 || die "Nix install failed"
fi
log "Configuring substituters..."
$SSH_K "sudo tee /etc/nix/nix.custom.conf >/dev/null <<CONF
experimental-features = nix-command flakes
trusted-users = root ${BOOTSTRAP_USER}
extra-substituters = ${CACHIX_SUB}
extra-trusted-public-keys = ${CACHIX_KEY}
CONF
grep -q nix.custom.conf /etc/nix/nix.conf || echo '!include nix.custom.conf' | sudo tee -a /etc/nix/nix.conf >/dev/null
sudo systemctl restart nix-daemon 2>/dev/null || true" || die "substituter config failed"

log "Rsyncing flake to the node..."
rsync -a --delete --exclude node-keys "${FLAKE_DIR}/" "${BOOTSTRAP_USER}@${IP}:/home/${BOOTSTRAP_USER}/hyperion-nixos/" \
    || die "flake rsync failed"

log "Staging decrypted secret tree..."
EXTRA="$(mktemp -d)"; chmod 700 "$EXTRA"
trap 'rm -rf "$EXTRA"' EXIT
age -d -i "$SOPS_AGE_KEY_FILE" "${FLAKE_DIR}/node-keys/${NAME}.tar.age" | tar -xf - -C "$EXTRA" \
    || die "could not decrypt ${NAME}.tar.age"
chmod 600 "$EXTRA/var/lib/sops-nix/key.txt" "$EXTRA/etc/ssh/ssh_host_ed25519_key"
$SSH_K 'rm -rf /tmp/hyp-extra && mkdir -p /tmp/hyp-extra'
rsync -a "$EXTRA"/ "${BOOTSTRAP_USER}@${IP}:/tmp/hyp-extra/" || die "secret rsync failed"

# ── Phase 4: confirm + flash the NVMe ───────────────────────────────────────
step "Phase 4 — flash NixOS onto /dev/nvme0n1"
if [ "$ASSUME_YES" -ne 1 ]; then
    warn "This ERASES /dev/nvme0n1 on ${NAME} (${IP}) and installs NixOS."
    read -r -p "Type the hostname to confirm: " C
    [ "$C" = "$NAME" ] || die "Confirmation mismatch — aborting."
fi

# Node-side flash: disko-install (tolerate sops-mount abort), then finish the
# bootloader via nixos-enter with util-linux on PATH. See header + memory.
$SSH_K "bash -s" <<NODESH || die "node-side flash failed (see output above)"
set -uo pipefail
NIX=${NIX}
echo '== disko-install (partition + closure + secret injection) =='
if mount | grep -q /dev/nvme0n1; then echo 'ABORT: nvme mounted'; exit 1; fi
sudo \$NIX run --accept-flake-config 'github:nix-community/disko/latest#disko-install' -- \
  --flake '/home/${BOOTSTRAP_USER}/hyperion-nixos#${NAME}' \
  --disk nvme0n1 /dev/nvme0n1 \
  --extra-files /tmp/hyp-extra/var/lib/sops-nix/key.txt /var/lib/sops-nix/key.txt \
  --extra-files /tmp/hyp-extra/etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key \
  --extra-files /tmp/hyp-extra/etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub \
  || echo '== disko-install returned nonzero (expected: sops mount aborts pre-bootloader) =='

echo '== finish activation + bootloader via nixos-enter (mount on PATH) =='
sudo mountpoint -q /mnt || sudo mount /dev/nvme0n1p2 /mnt
sudo mkdir -p /mnt/boot/firmware
sudo mountpoint -q /mnt/boot/firmware || sudo mount /dev/nvme0n1p1 /mnt/boot/firmware
ULBIN=\$(dirname "\$(sudo find /mnt/nix/store -maxdepth 3 -path '*-util-linux-*/bin/mount' 2>/dev/null | grep -v minimal | head -1 | sed 's#^/mnt##')")
[ -n "\$ULBIN" ] || { echo 'ABORT: util-linux not in closure'; exit 1; }
sudo \$NIX shell nixpkgs#nixos-install-tools --accept-flake-config -c \
  nixos-enter --root /mnt -c "export PATH=\$ULBIN:\\\$PATH; /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
echo '== verify bootloader staged =='
sudo test -e /mnt/boot/firmware/kernel.img && sudo test -e /mnt/boot/firmware/initrd \
  && echo 'BOOTLOADER_OK' || { echo 'BOOTLOADER_MISSING'; exit 1; }
echo '== shred staged secret tree (SD is portable) =='
sudo find /tmp/hyp-extra -type f -exec shred -u {} \; 2>/dev/null; sudo rm -rf /tmp/hyp-extra
sudo umount -R /mnt 2>/dev/null || true
NODESH
log "NVMe flashed + bootloader staged."

# ── Phase 5: EEPROM boot order + reboot ─────────────────────────────────────
step "Phase 5 — set EEPROM BOOT_ORDER=${BOOT_ORDER} (NVMe-first) + reboot"
$SSH_K "bash -s" <<NODESH || die "EEPROM/reboot step failed"
set -e
sudo rpi-eeprom-config > /tmp/ee.cur
sed 's/^BOOT_ORDER=.*/BOOT_ORDER=${BOOT_ORDER}/' /tmp/ee.cur > /tmp/ee.new
grep -q '^BOOT_ORDER=${BOOT_ORDER}' /tmp/ee.new || echo 'BOOT_ORDER=${BOOT_ORDER}' >> /tmp/ee.new
sudo rpi-eeprom-config --apply /tmp/ee.new >/dev/null
echo 'EEPROM staged ${BOOT_ORDER}'
sudo systemd-run --on-active=2 systemctl reboot >/dev/null 2>&1 || (sudo reboot &)
NODESH
log "Rebooting ${NAME} into NVMe NixOS..."
ssh-keygen -R "$IP" >/dev/null 2>&1 || true   # drop the bootstrap host key from the operator's known_hosts

# ── Phase 6: verify boot + k3s ──────────────────────────────────────────────
step "Phase 6 — verify NixOS boot + k3s"
# The node's SSH host key changes from the bootstrap key to the injected NixOS
# one across the reboot. accept-new CANNOT reconcile a *changed* key (it errors
# "REMOTE HOST IDENTIFICATION HAS CHANGED"), and the poll below would re-add the
# bootstrap key during the reboot delay and then spin forever. We injected and
# trust this host key, so the verify path ignores host-key state entirely
# (no=auto-accept, /dev/null=don't read or pollute the operator's known_hosts).
SSH_O="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${TARGET_USER}@${IP}"
log "Waiting for ${NAME} to return as NixOS (up to 5 min)..."
deadline=$(( $(date +%s) + 300 ))
until $SSH_O 'grep -q NixOS /etc/os-release' 2>/dev/null; do
    [ "$(date +%s)" -gt "$deadline" ] && die "Node did not return as NixOS in time — check console."
    sleep 6
done
log "  ${GREEN}NixOS is up.${NC}"
$SSH_O 'echo "  root: $(findmnt -nro SOURCE /)"; echo "  sops: $(sudo test -s /run/secrets/k3s-token && echo decrypted || echo MISSING)"; echo "  k3s:  $(systemctl is-active k3s)"' 2>&1

echo ""
log "${GREEN}✓ ${NAME} is installed on NVMe and booting NixOS.${NC}"
echo "  Confirm cluster join from the control plane:"
echo "    ssh ${TARGET_USER}@192.168.10.4 'docker exec k3s-control-plane-k3s-server-1 kubectl get nodes'"
echo "  ${NAME} should reach Ready within ~1 min (control plane must be up)."
echo ""
echo "  You can now move the bootstrap SD to the next node and run:"
echo "    ./setup-hyperion-node.sh --name hyperion-<next> --ip <its-ip>"
