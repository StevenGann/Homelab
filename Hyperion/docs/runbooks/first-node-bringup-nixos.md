# First-node bring-up (NixOS) — Phase 1 walkthrough

> ⚠️ **Partially superseded (2026-05-25).** The install mechanism changed to
> nixos-anywhere from a live SD installer — see
> [`remote-flash-a-node.md`](./remote-flash-a-node.md) and
> [ADR-0001](../../../docs/design/adr-0001-nixos-anywhere-remote-flash.md).
> The HYPERION-ID USB, `dd`-to-NVMe, `apply-identity`, and identity-overrides
> steps below are **retired**. The Phase 1 gate *criteria* (k3s joins,
> journald ships, reboot survives) still apply; the *procedure* is now
> register-node-key.sh → boot SD installer → flash-node.sh. Full rewrite is a
> tracked follow-up.

The Phase 1 hard gate of the NixOS pivot. Target: bring `hyperion-alpha`
up end-to-end on NixOS, confirm the gate criteria, decide go/no-go for
Phase 2.

> **Read first:** the design rationale in `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/FINAL.md` (local-only). The plan body lives in `iter-1/04-revision.md` and `iter-2/04-revision.md`.

## Prerequisites (workstation)

Install on the workstation (one-time):

- Nix (Determinate or upstream)
- `age` from <https://github.com/FiloSottile/age>
- `sops` from <https://github.com/getsops/sops>
- `colmena` (`nix shell nixpkgs#colmena` works for now)
- `mkfs.ext4` (e2fsprogs — usually already present)
- A USB-to-NVMe adapter or external NVMe enclosure (the Pi's NVMe is
  flashed on the workstation, then moved into the Pi)
- The age private key for the operator's existing SOPS scope at
  `~/.config/sops/age/keys.txt`

Confirm:

```bash
nix --version
age-keygen --version
sops --version
colmena --version
```

## Phase 0 confirmation

The Phase 0 commit cut existing aarch64 workflows to `ubuntu-24.04-arm`.
Before continuing, verify it landed clean:

```bash
gh run list -w 'Build Bootstrap IMG' -L 1 -b main
gh run list -w 'Build and publish Node IMG' -L 1 -b main
```

Both should show `success` on the most recent run. If either is queued
or failing, sort it out before continuing.

## Step 1 — Fill in placeholders in the flake

Three placeholders in the scaffold need real values before the first build:

1. **Operator SSH pubkey.** Edit `Hyperion/nixos/modules/hyperion-base.nix`
   under `users.users.owner.openssh.authorizedKeys.keys`. Paste the
   operator's actual `ssh-ed25519 ...` line.

2. **Colmena pin.** Edit `Hyperion/nixos/flake.nix`,
   `inputs.colmena.url`, pinning to a specific 2025-11 commit hash. Run
   `nix flake lock --update-input colmena` to refresh `flake.lock`.

3. **k3s version alignment.** The workers run k3s 1.34.5 (from nixpkgs
   nixos-25.11). The Heimdall control plane is pinned to the matching
   `rancher/k3s:v1.34.5-k3s1`. Same-minor = no skew workaround needed.
   Bump in lockstep when you bump nixpkgs.

## Step 2 — Flash the alpha identity USB

```bash
cd ~/GitHub/Homelab/Hyperion
sudo ./flash-identity-usb.sh /dev/sdX hyperion-alpha
```

The script:
- formats the USB as ext4 (label `HYPERION-ID`)
- copies `nixos/identity-overrides/hyperion-alpha.env` → `/identity.env`
- generates a per-node age keypair → `/age-key.txt` (private, 0400)
- generates persistent SSH host keys → `/secrets/`
- writes `/meta/schema-version=2`

It prints the per-node **age pubkey** at the end (`age1...`). Capture it
for Step 3.

## Step 3 — Register alpha's age key

The companion script appends the pubkey to `Hyperion/.sops.yaml` under
the `nixos/secrets/*.yaml` creation_rule and runs `sops updatekeys` on
any existing encrypted files (none yet on the first node — that's fine):

```bash
cd ~/GitHub/Homelab/Hyperion
./register-node-key.sh hyperion-alpha age1<pubkey-from-step-2>
```

## Step 4 — Mint the k3s join token

The token must exist in two encrypted files: `Heimdall/secrets/k3s-control-plane.sops.env` (for the k3s server container) and
`Hyperion/nixos/secrets/common.yaml` (for the workers, via sops-nix).
Both hold the **same** plaintext, encrypted to different recipient sets.

Detailed walkthrough: `Heimdall/k3s-control-plane/README.md` §"Initial
mint". One-block form (each `sops` invocation runs from the host
directory that owns its `.sops.yaml`, since sops walks up from cwd):

```bash
TOKEN=$(openssl rand -hex 32)

cd ~/GitHub/Homelab/Heimdall
printf 'K3S_TOKEN=%s\n' "$TOKEN" > secrets/k3s-control-plane.sops.env
sops --encrypt --input-type dotenv --output-type dotenv --in-place \
    secrets/k3s-control-plane.sops.env

cd ~/GitHub/Homelab/Hyperion
mkdir -p nixos/secrets
printf 'k3s-token: %s\n' "$TOKEN" > nixos/secrets/common.yaml
sops --encrypt --in-place nixos/secrets/common.yaml

unset TOKEN
```

Commit:

```bash
cd ~/GitHub/Homelab
git add Heimdall/secrets/k3s-control-plane.sops.env Hyperion/nixos/secrets/common.yaml
git commit -m "feat: mint k3s join token"
```

## Step 5 — Deploy the Heimdall control plane

```bash
bash Heimdall/scripts/deploy.sh
```

`deploy.sh` decrypts both env files on the workstation, ships cleartext
to Heimdall via SSH, then brings up the k3s control plane container.
Verify on Heimdall:

```bash
ssh owner@192.168.10.4 'docker compose -f /opt/Homelab/Heimdall/k3s-control-plane/docker-compose.yml ps'
ssh owner@192.168.10.4 'sudo curl -ksf https://localhost:6443/readyz'   # → "ok"
```

The control plane is now listening on `https://192.168.10.4:6443` and
waiting for worker registrations.

## Step 6 — Build the installer image

Two paths.

**Path A — CI build (preferred):** push to main, wait for the
`Build Hyperion NixOS image` workflow to finish (~25 min cold,
~5–10 min cached), download the artifact:

```bash
gh run watch
# Once green:
gh release download nvme-$(date -u +%Y%m%d)-... --pattern '*.img.zst'
```

**Path B — Local build (if you're iterating):**

```bash
cd Hyperion/nixos
nix build .#installerSdImage --print-build-logs
ls -lh result/sd-image/*.img
```

## Step 7 — Flash NVMe (workstation)

Put the blank Pi 5 NVMe in a USB-to-NVMe adapter on the workstation.
Confirm the device path with `lsblk` — it'll be something like `/dev/sdb`
(NOT `/dev/nvme0n1` unless the workstation has its own M.2 slot).

```bash
zstd -d hyperion-nvme-*.img.zst | sudo dd of=/dev/sdb bs=4M conv=fsync status=progress
sync
```

Verify the partitions appeared:

```bash
lsblk /dev/sdb
# Expect: firmware (FAT32), root (ext4), node-storage (ext4)
```

## Step 8 — Insert in alpha

1. Power off `hyperion-alpha` if it's running.
2. Move the freshly-flashed NVMe from the workstation adapter into
   alpha's M.2 HAT.
3. Insert the HYPERION-ID identity USB into one of alpha's USB ports.
4. Verify EEPROM is configured for NVMe-first boot: `./configure-eeprom.sh hyperion-alpha --reboot` if not already done.
5. Power on alpha.

## Step 9 — Validate the gate criteria

Five things must hold for the Phase 1 hard gate to pass. Track them in a
local `intervention-log.md`:

### Gate 1 — NVMe boots (cold)

Wait ~30 seconds, then:

```bash
ssh owner@192.168.10.101
# Should connect with the operator key (added in Step 1).
hostnamectl
# Static hostname should read: hyperion-alpha
```

If SSH fails:
- Try `arp -an | grep -i 'b8:27:eb\|d8:3a:dd\|dc:a6:32'` to confirm the Pi got a DHCP lease.
- If on the LAN but SSH refuses: connect a USB keyboard + HDMI to alpha and read the console. The most likely issue is `apply-identity.service` failing (USB schema mismatch or mount race).

### Gate 2 — apply-identity succeeded

```bash
ssh owner@192.168.10.101 'systemctl status apply-identity'
# Expect: active (exited)
ssh owner@192.168.10.101 'cat /run/hyperion/identity.env'
# Expect: HYPERION_HOSTNAME=hyperion-alpha, HYPERION_NODE_IP=192.168.10.101
```

### Gate 3 — k3s agent registered with the Heimdall control plane

```bash
# Quickest path: ask the control plane container directly.
ssh owner@192.168.10.4 'sudo docker exec $(docker ps -qf name=k3s-server) k3s kubectl get nodes'
# Expect: hyperion-alpha appears with status Ready
```

For repeat use, fetch the kubeconfig once per `Heimdall/k3s-control-plane/README.md` §"Getting kubectl access", then `kubectl get nodes` from the workstation.

### Gate 4 — journal-upload reaches Heimdall

```bash
ssh owner@192.168.10.4 'curl -s http://localhost:19531/browse | head -20'
# Expect: HTML page lists hyperion-alpha as a journal source
```

(`journal-remote` runs on Heimdall via `Heimdall/hyperion/docker-compose.yml`;
`hyperion-journal.nix` ships there at `192.168.10.4:19532`.)

### Gate 5 — Warm reboot survives (the load-bearing one)

This is the rpi-eeprom #718 discriminator. If alpha can warm-reboot into
NVMe without a power cycle, the pivot has actually fixed something.

```bash
ssh owner@192.168.10.101 'sudo reboot'
# Wait ~60 seconds
ssh owner@192.168.10.101 'uptime'
# Expect: uptime < 2 min, hostname still hyperion-alpha
```

If warm reboot fails (alpha drops off the network and doesn't come back
within 90 seconds), you've hit #718. Two options:
- Power-cycle alpha manually; document that warm reboot is unreliable on
  this hardware. (This is honest and doesn't fail the gate by itself —
  the workaround is documented in `replace-dead-node.md`.)
- Halt Phase 1, attempt an EEPROM firmware update via `configure-eeprom.sh`, retry. If still fails after current-firmware-2712, the pivot has not bought us anything operationally — see the FINAL.md §B-1 H4 discriminator paragraph.

## Step 10 — Soak

Leave alpha running for 24 hours. Track:
- `kubectl get nodes` continuously shows Ready
- `journalctl -u k3s -f` clean (no flapping)
- Cumulative unplanned operator-intervention time (logged in `intervention-log.md`)

## Phase 1 exit decision

Three independent halt signals; any of them halts and triggers iter-3
with Counter-B promoted:

1. **Hard gate:** NVMe boot failed twice. Halt.
2. **Muddy-failure:** >6 hrs intervention in any rolling 7-day window
   during this phase. Halt.
3. **Behavioral:** <3 commits to `Hyperion/nixos/`, workflows, or
   `flash-identity-usb.sh` in the first 5 days of Phase 1 work. Halt.

If all three signals stay green, proceed to Phase 2 (hyperion-beta,
the 4 GB node) per `Hyperion/docs/runbooks/replace-dead-node.md` Step
"Second node bring-up."

## What to do on success

Update `docs/todo.md` to mark Phase 1 complete and move to Phase 2.
Commit a short note in this runbook recording the actual wall-clock,
the actual Cachix hit rate, and any unexpected behaviors.
