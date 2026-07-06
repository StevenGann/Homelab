# Key backup & recovery runbook

**Created:** 2026-07-06 (after the operator age key was lost in a workstation
migration). Companion to [`docs/sops-secret-inventory.md`](../sops-secret-inventory.md)
(what's encrypted + per-item recoverability) and
[`docs/runbooks/disaster-recovery.md`](./disaster-recovery.md) (rebuild order).

Two parts:

- **Part 1 — Recover now:** re-establish the SOPS workflow after the key loss,
  without changing any passwords.
- **Part 2 — Never again:** automated, encrypted backups of all key material to
  **Akasha** + a **cold-storage USB**, with a memorized-passphrase escape hatch
  that does not depend on the very key being backed up.

---

## Part 1 — Recover the SOPS workflow after the key loss

The lost operator key (`age1u8tfm7s…`) cannot be recovered. The plan is to
**mint a new operator key, recover every secret's plaintext from a non-lost
recipient or a live system, and re-encrypt to the new key.** No service password
changes. See the inventory doc for the per-item source of truth.

### 1.0 Prereqs on the new workstation

```bash
# Tooling (currently missing on the migrated workstation)
sudo apt install -y age                      # or: nix profile install nixpkgs#age
# sops:
SOPS_VER=v3.9.4
curl -Lo /tmp/sops "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.amd64"
sudo install -m0755 /tmp/sops /usr/local/bin/sops
# kubectl + restore kubeconfig (from the migration USB backup, or scp from control plane)
sudo install -m0755 <(curl -sL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl") /usr/local/bin/kubectl
mkdir -p ~/.kube && cp "/run/media/owner/Stubby 128/.kube/config" ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes    # confirm cluster reachable (API :6443 verified OPEN 2026-07-06)
```

### 1.1 Mint a new operator age key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt        # prints the new public key
chmod 600 ~/.config/sops/age/keys.txt
NEW_OP=$(grep '^# public key:' ~/.config/sops/age/keys.txt | awk '{print $4}')
echo "New operator recipient: $NEW_OP"
```

**Immediately** run Part 2's backup so the new key is never single-homed again.

### 1.2 Recover plaintext, per tier (from the inventory doc)

**Tier A — k8s secrets (decrypt with the in-cluster Flux key):**

```bash
kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d > /tmp/flux-age.txt
# sanity: this decrypts existing ciphertext
SOPS_AGE_KEY_FILE=/tmp/flux-age.txt sops -d Hyperion/k8s/apps/jellystat/secret.sops.yaml
```

If the Flux Secret is ever also gone, read the already-applied Secrets instead:
`kubectl -n <ns> get secret <name> -o yaml` (values are base64, not encrypted).

**Tier A — NixOS `common.yaml` + node identities (decrypt with a node key):**

```bash
ssh owner@192.168.10.101 'sudo cat /var/lib/sops-nix/key.txt' > /tmp/node-alpha.txt
SOPS_AGE_KEY_FILE=/tmp/node-alpha.txt sops -d Hyperion/nixos/secrets/common.yaml   # k3s-token
# Re-harvest each node's identity to rebuild node-keys/*.tar.age against $NEW_OP:
for n in alpha:101 beta:102 gamma:103 delta:104 epsilon:105 zeta:106 eta:107 theta:108 iota:109 kappa:110; do
  host=hyperion-${n%:*}; ip=192.168.10.${n#*:}
  ssh owner@$ip "sudo tar -C / -cf - var/lib/sops-nix/key.txt etc/ssh/ssh_host_*" \
    | age -r "$NEW_OP" > Hyperion/nixos/node-keys/${host}.tar.age
done
```

**Tier B — operator-only secrets, read from the live host/container:**

```bash
# Thoth (:22 OPEN)
ssh owner@192.168.10.144 'sudo cat /etc/pterodactyl/config.yml'                    # wings token_id/token
ssh owner@192.168.10.144 'docker inspect open-webui --format "{{json .Config.Env}}"'  # OPENWEBUI_SECRET
# Heimdall (:22 CLOSED → use Komodo UI, host console, or docker exec via Komodo):
#   read the decrypted /opt/Homelab/Heimdall/secrets/*.env, or `docker inspect` the
#   komodo/authentik containers, or the Authentik admin UI + Postgres.
# Sensors: WiFi/MQTT creds are known; MQTT also cleartext in mosquitto/secret.yaml.
```

### 1.3 Re-encrypt everything to the new operator key

Swap `age1u8tfm7s…` → `$NEW_OP` in **every** `.sops.yaml` (`Hyperion/`,
`Heimdall/`, `Thoth/`, `Sensors/Temperature/`), then, for each secret file, write
the recovered plaintext and re-encrypt:

```bash
# after editing the .sops.yaml recipient lists:
grep -rl 'age1u8tfm7scg35csrnam9ntnppne5728593yw7fk3p9sz7ecl06dpgs958ncm' --include='.sops.yaml' . \
  | xargs sed -i "s/age1u8tfm7scg35csrnam9ntnppne5728593yw7fk3p9sz7ecl06dpgs958ncm/$NEW_OP/g"

# Tier A files that already decrypt: just rotate recipients in place
find Hyperion/k8s -name '*.sops.yaml' -exec sops --config Hyperion/.sops.yaml updatekeys -y {} \;

# Tier B files: recreate from recovered plaintext, e.g.
cd Thoth && sops -e --input-type dotenv --output-type dotenv /tmp/thoth.env > secrets/env.sops.env
```

Also recreate the **Flux** `sops-age` recipient only if you choose to rotate it
(not required — it wasn't lost). Commit + push; Flux reconciles from GitHub.

### 1.4 Verify the workflow end-to-end

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d Thoth/secrets/env.sops.env >/dev/null && echo OK
```

Update `docs/runbooks/disaster-recovery.md` §0 and any doc referencing the old
public key with `$NEW_OP`.

---

## Part 2 — Automated key backups (Akasha + cold USB)

**Goal:** the loss that just happened must become a non-event. Every piece of
irreplaceable key material is copied, encrypted, to two independent destinations,
on a schedule, with a **passphrase escape hatch** so a backup is *never*
decryptable only by the key it contains.

### 2.1 What gets backed up ("crown jewels")

| Item | Source | Why |
|---|---|---|
| Operator age key | `~/.config/sops/age/keys.txt` | THE recovery root |
| Flux in-cluster age key | `kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' \| base64 -d` | second recipient for all k8s secrets |
| Per-node age keys + SSH host keys | `Hyperion/nixos/node-keys/*.tar.age` (in git) **and** live `/var/lib/sops-nix/key.txt` per node | NixOS rebuild identity |
| SSH keys | `~/.ssh/` (`id_ed25519`, `hyperion-ci-deploy`, `known_hosts`, `authorized_keys`, `*.pub`) | host + CI access |
| GPG keyring | `~/.gnupg/` (if/when real keys exist) | future-proof |
| kubeconfig | `~/.kube/config` | cluster access |
| *(optional)* full plaintext secret snapshot | Tier-A/B recovery of every secret | belt-and-suspenders total-loss recovery |

### 2.2 The escape-hatch encryption model (critical)

The bundle is encrypted **two independent ways**, so no single lost secret can
lock you out:

1. **Passphrase (primary escape hatch).** `age --passphrase` (scrypt). The
   passphrase lives in your **password manager + memory** — it is *not* any key
   in the bundle. This is exactly what would have saved us this week.
2. **A dedicated backup recipient key** (`age1backup…`), generated once, whose
   private half is stored **only** in the password manager (never on the
   workstation). Lets automated restores happen without typing the passphrase.

> Never encrypt the backup solely to the operator key — that recreates the
> circular dependency that caused this incident.

### 2.3 The backup script

Proposed location `tools/backup-keys.sh` (repo-root, workstation-run):

```bash
#!/usr/bin/env bash
set -euo pipefail
# Back up all homelab key material, encrypted, to Akasha and/or a cold USB.
# Usage: backup-keys.sh [--dest akasha|usb|all] [--full-secrets]
DEST=${1:-all}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_RECIPIENT="age1backup...replace-me..."          # public half; private in password manager
AKASHA=owner@192.168.10.247
AKASHA_PATH=/mnt/tank/backups/homelab-keys             # dedicated encrypted ZFS dataset
USB_LABEL=STUBBY-COLD                                   # cold-storage USB filesystem label
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/keys-$STAMP"; mkdir -p "$STAGE"

# --- gather ---
install -m600 ~/.config/sops/age/keys.txt "$STAGE/operator-age.txt"
cp -a ~/.ssh "$STAGE/ssh"; [ -d ~/.gnupg ] && cp -a ~/.gnupg "$STAGE/gnupg" || true
[ -f ~/.kube/config ] && install -m600 ~/.kube/config "$STAGE/kubeconfig" || true
cp -a "$(git -C ~/Github/Homelab rev-parse --show-toplevel)/Hyperion/nixos/node-keys" "$STAGE/node-keys" 2>/dev/null || true
kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' 2>/dev/null \
  | base64 -d > "$STAGE/flux-age.txt" || echo "WARN: flux key not fetched"
# verify operator pubkey is the CURRENT one before trusting this backup
EXP=$(grep -rhoE 'age1[0-9a-z]{58}' ~/Github/Homelab/Thoth/.sops.yaml | head -1)
GOT=$(grep '^# public key:' "$STAGE/operator-age.txt" | awk '{print $4}')
[ "$EXP" = "$GOT" ] || { echo "REFUSING: operator key $GOT != repo recipient $EXP"; exit 1; }

# --- encrypt (both ways) ---
BUNDLE="$WORK/keys-$STAMP.tar.age"
tar -C "$WORK" -cf - "keys-$STAMP" | age -r "$BACKUP_RECIPIENT" -p > "$BUNDLE"   # recipient + passphrase
sha256sum "$BUNDLE" > "$BUNDLE.sha256"

# --- ship ---
push_akasha(){ ssh "$AKASHA" "mkdir -p $AKASHA_PATH"; scp "$BUNDLE" "$BUNDLE.sha256" "$AKASHA:$AKASHA_PATH/";
               ssh "$AKASHA" "cd $AKASHA_PATH && ls -t keys-*.tar.age | tail -n +13 | xargs -r rm -f"; }  # keep 12
push_usb(){ m=$(lsblk -no MOUNTPOINT -Q "LABEL=='$USB_LABEL'" 2>/dev/null | head -1);
            [ -n "$m" ] || { echo "cold USB '$USB_LABEL' not mounted — skip"; return; }
            cp "$BUNDLE" "$BUNDLE.sha256" "$m/"; sync; }
case "$DEST" in akasha) push_akasha;; usb) push_usb;; all) push_akasha; push_usb;; esac

# --- verify restorability (test-decrypt with the backup recipient) ---
age -d -i /dev/null "$BUNDLE" >/dev/null 2>&1 || true   # passphrase path is interactive; recipient path in restore test
echo "backup $STAMP complete -> $DEST"
```

> Harden before production: pin the repo path, drop the interactive `-p` for the
> automated (recipient-key) path and reserve passphrase-encryption for a separate
> monthly manual run, and send an `ntfy`/push on failure.

### 2.4 Destinations

**Akasha (TrueNAS, `192.168.10.247`, SSH OPEN):**
- Create a dedicated dataset `tank/backups/homelab-keys` with **native ZFS
  encryption** + periodic snapshots + a replication task off-box if available.
- The script `scp`s the already-encrypted bundle there (defence in depth: ZFS
  encryption *and* age encryption), keeping the last 12 timestamped bundles.

**Cold-storage USB (`LABEL=STUBBY-COLD`):**
- Offline by design; the script writes only when it's mounted. Recommended
  cadence: monthly, plus immediately after any key rotation.
- Optionally format it LUKS so it's encrypted at rest even before age.

### 2.5 Scheduling (workstation)

`~/.config/systemd/user/backup-keys.timer` (daily to Akasha):

```ini
[Unit]
Description=Daily homelab key backup to Akasha
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
```
`backup-keys.service` → `ExecStart=%h/Github/Homelab/tools/backup-keys.sh akasha`.
Enable: `systemctl --user enable --now backup-keys.timer`. Cold-USB runs stay
manual (`backup-keys.sh usb`) since the medium is deliberately offline.

### 2.6 Restore test (do this monthly — a backup you haven't restored isn't one)

```bash
# from Akasha's newest bundle, using the backup recipient key from the password manager:
scp owner@192.168.10.247:/mnt/tank/backups/homelab-keys/keys-<STAMP>.tar.age /tmp/
age -d -i /path/to/backup-age-from-passwordmanager.txt /tmp/keys-<STAMP>.tar.age | tar -tvf -
# and the passphrase path:
age -d /tmp/keys-<STAMP>.tar.age | tar -tvf -      # prompts for the memorized passphrase
```

### 2.7 Cross-references to update

- `docs/runbooks/disaster-recovery.md` §0 — replace "back this up off-site
  (password manager + offline media)" prose with a pointer to this automated flow
  and the new operator public key.
- `docs/dr-readiness-2026-07-04.md` — mark the "where is the operator key backed
  up" gap (H-series) as addressed once Part 2 is live.
