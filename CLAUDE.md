# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Convention

Top-level directories map to **physical hosts or clusters**:

- `Hyperion/` — the 10-node Raspberry Pi 5 k3s worker cluster
- `Monolith/` — the TrueNAS Scale host at `192.168.10.247` (k3s server, image registry, CI deploy poller, healthcheck)
- `docs/` — repo-wide design and planning docs

This pattern extends as IaC coverage grows. New hosts get their own top-level directory.

For working on this repo with the standing agent team, see [`TEAM.md`](TEAM.md) (roster, roles, notes protocol) and [`PIPELINES.md`](PIPELINES.md) (DEVELOPMENT and DEBUGGING orchestration). Agent notes live under `docs/agent-notes/`; pipeline runs under `docs/pipeline-runs/`.

`README.md` is the authoritative entry point — it describes the directory layout and the bring-up sequence. `docs/todo.md` tracks the operational state (what's been done, what remains). `docs/hyperion-iac-plan.md` is **archived/obsolete** (PXE/TFTP approach that was abandoned) — do not follow it. `docs/design/node-image-approach.md` is the implemented design but contains a "Known divergences from implementation" section at the top; for current behavior, **read the code and `Hyperion/docs/runbooks/`**, not the design doc body.

## Architecture — the two-image model

The single most important concept in this repo is the **Bootstrap IMG + Node IMG split**. Most files in `Hyperion/packer/` only make sense once you understand it:

```
GitHub push (main, Packer files changed)
  → CI builds image with Packer (ARM64 via QEMU on ubuntu-latest)
  → Publishes to GitHub Releases (tags: node-v<EPOCH>, bootstrap-latest)

Monolith ci-deploy container (polls GitHub every 5 min)
  → Downloads release asset → decompresses → places under /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}/
  → nginx (port 50011) serves these to the LAN

Pi node boot (BOOT_ORDER=0xf641 → SD → USB → NVMe → loop)
  ├── Bootstrap media inserted (SD card OR USB stick — either works) → Bootstrap IMG runs
  │     1. Reads identity from HYPERION-ID USB (per-node hostname + image cache)
  │     2. If Monolith reachable AND has newer Node IMG → updates USB cache
  │     3. If USB cache version > NVMe version → dd USB → NVMe → repartition → reboot
  │     4. Else → reboot into NVMe
  └── No bootstrap media → boots straight into NVMe (Node IMG / production)
```

**Key invariants:**
- **USB-authoritative.** Network updates the USB cache; USB flashes NVMe. Never network → NVMe directly. This means a node can be re-imaged from cached USB image with no network at all.
- **Identity travels on the HYPERION-ID USB stick**, not the hardware. Replacing a dead Pi: move its USB stick to the new Pi, update the MAC in the UCG DHCP reservation, power on.
- **Bootstrap SD is identical across all 10 nodes** — one card can be moved between nodes during imaging.
- **EEPROM** (`BOOT_ORDER=0xf641`) is the only thing that's truly per-Pi-and-permanent. Lives in SPI flash, unaffected by re-imaging.
- **Bootstrap is idempotent and boot-loop protected.** Stops after `MAX_BOOT_ATTEMPTS=3` and drops to a shell. The version-stamp wipe happens *before* repartition, so a mid-flash failure causes a re-flash next boot rather than booting into a broken NVMe.

The systemd unit `mnt-node-storage.mount` is the **sole** mechanism that mounts `/mnt/node-storage`. Bootstrap deliberately does not write a fstab entry for p3 — that would create a duplicate-unit conflict.

## Common commands

All operator scripts are in `Hyperion/`. Run from there.

```bash
# Build + publish images locally (only needed before CI is configured; otherwise CI does it)
export NODE_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./publish-image.sh node                # builds, zstd -19, creates GitHub Release node-v<EPOCH>
./publish-image.sh bootstrap           # builds, creates/replaces bootstrap-latest release
./publish-image.sh node --dry-run      # build only; output at packer/output/rpi-node.img

# Per-node identity USB (one per node, before first bootstrap)
./flash-identity-usb.sh /dev/sdX hyperion-alpha

# EEPROM boot order (one-time per Pi, or after replacing SPI flash)
./configure-eeprom.sh --user owner --reboot               # all 10 nodes
./configure-eeprom.sh hyperion-alpha --user owner --reboot

# Re-image (Bootstrap SD/USB must be physically inserted first)
./reimage.sh hyperion-alpha
./reimage.sh all

# Post-imaging configuration
cd ansible && ansible-playbook -i inventory.yaml bootstrap.yml
ansible-playbook -i inventory.yaml bootstrap.yml --limit hyperion-alpha
```

CI is triggered automatically on push to `main` for paths under `Hyperion/packer/`. Both image workflows use `concurrency: build-images` so they serialize.

## Node image internals (when editing Packer files)

`Hyperion/packer/rpi-node.pkr.hcl` provisioner order matters — see `Hyperion/docs/runbooks/build-packer-image.md` for the full table. Things that bite if changed:

- The `pi` user is **deleted** during build; the active SSH user is `owner`. SSH key comes from `NODE_SSH_PUBLIC_KEY`.
- cloud-init is **purged** (`apt-get purge cloud-init; rm -rf /etc/cloud /var/lib/cloud`). Do not reintroduce it — identity comes from `apply-identity.service` reading the HYPERION-ID USB.
- k3s is **installed but not enabled** (`INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true`). Ansible starts it later.
- Pi 5 NVMe boot requires the `[pi5]` block in `config.txt` with `kernel=kernel_2712.img`, `auto_initramfs=1`, `dtparam=pciex1_gen=3` (Gen 3 — overclock from spec Gen 2; verify with HAT/SSD compatibility before changing), `dtparam=nvme`.
- Root auto-expansion is disabled; Bootstrap handles all NVMe partitioning.
- `/boot/firmware/node-img.ver` is the version stamp Bootstrap reads to decide whether to re-flash. It's a Unix epoch integer.

## Secrets

SOPS + age. The age public key is in `Hyperion/.sops.yaml`. Private key lives at `~/.config/sops/age/keys.txt` on the workstation only — never committed.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>
```

The only required GitHub Actions secret is `NODE_SSH_PUBLIC_KEY` (CI uses the auto-provided `GITHUB_TOKEN` for releases). The Monolith deploy-key approach described in §13 of the design doc was abandoned — Monolith **pulls** from GitHub via the ci-deploy container instead.

## Network reference

Single VLAN `192.168.10.0/24`. UCG (`.1`) is the DHCP server.

| Range | Purpose |
|-------|---------|
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion nodes (alpha → kappa, in Greek-letter order) |
| `.247` | Monolith (k3s server :6443, nginx image server :50011, healthcheck API :50012) |

Bootstrap status endpoint runs on `:8080` of each Pi while imaging is in progress.

## When you change something

- **Packer files under `Hyperion/packer/`** → CI rebuilds the relevant image automatically. Test on one node (`./reimage.sh hyperion-alpha`) before rolling to all.
- **Bootstrap script (`bootstrap.sh`)** → triggers a Bootstrap IMG rebuild only. Existing identity USBs and Node IMG cache continue working.
- **Node IMG provisioner steps** → triggers a Node IMG rebuild. Bumps `current_version` in the published manifest, which propagates via ci-deploy → USB cache → NVMe re-flash on next bootstrap.
- **`Monolith/k3s-control-plane/docker-compose.yml`** → not auto-deployed. Re-run `docker compose up -d` on Monolith manually (see `Monolith/k3s-control-plane/docs/runbooks/preflight.md`).
- **k8s manifests under `Hyperion/k8s/`** → reconciled by FluxCD (when bootstrapped — currently TODO per `docs/todo.md` Step 10).
