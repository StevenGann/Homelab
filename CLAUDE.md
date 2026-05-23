# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Convention

Top-level directories map to **physical hosts or clusters**:

- `Hyperion/` — the 10-node Raspberry Pi 5 k3s worker cluster
- `Monolith/` — the TrueNAS Scale host at `192.168.10.247` (k3s server + healthcheck)
- `Heimdall/` — edge-services host at `192.168.10.4` (Caddy reverse proxy, Technitium DNS, Komodo container manager; **also hosts the Hyperion flashing services** moved from Monolith on 2026-05-21)
- `docs/` — repo-wide design and planning docs

This pattern extends as IaC coverage grows. New hosts get their own top-level directory.

For working on this repo with the standing agent team, see [`TEAM.md`](TEAM.md) (roster, roles, notes protocol) and [`PIPELINES.md`](PIPELINES.md) (DEVELOPMENT and DEBUGGING orchestration). Agent notes live under `docs/agent-notes/`; pipeline runs under `docs/pipeline-runs/` are git-ignored by convention (the agent-notes Settled-knowledge sections are the durable record).

`README.md` is the authoritative entry point. `docs/todo.md` tracks operational state. `docs/hyperion-iac-plan.md` and the body of `docs/design/node-image-approach.md` are **archived/obsolete** — do not follow them for current behavior. For current state, **read the code and `Hyperion/docs/runbooks/`**.

## Hyperion architecture — pivot in progress (2026-05-23)

The single most important thing to know about Hyperion right now: **it is mid-pivot from Debian/Packer to NixOS**. Both stacks coexist in-tree until the 2026-08-15 sunset gate. The decision was approved by a 6-YAE / 0-NAY vote across 2 iterations of the standing-team DEVELOPMENT pipeline (run `20260523T050133Z-dev-nixos-identity-usb/`, FINAL.md lives in the run folder locally per `.gitignore`).

### NixOS architecture (the forward path)

Files: `Hyperion/nixos/` — full scaffold landed but **not yet hardware-validated** (Phase 1 hard gate).

```
GitHub push (Hyperion/nixos/**, main)
  → CI builds installer image via nix on ubuntu-24.04-arm (5-25 min)
  → Publishes to GitHub Releases (tag: nvme-<datestamp>-<sha>)

Heimdall ci-deploy (polls GitHub every 5 min — moved from Monolith 2026-05-21)
  → Downloads release asset to /opt/Homelab/Heimdall/hyperion/images/nvme/
  → nginx (192.168.10.4:50011) serves to the LAN

First install per Pi (operator-driven, once per kernel/firmware bump):
  Workstation: zstd -d <img.zst> | sudo dd of=/dev/sdX (USB-to-NVMe adapter)
  Move NVMe into Pi
  Insert HYPERION-ID identity USB
  Power on
  → Pi 5 EEPROM boots kernel.img from FAT firmware partition on NVMe
  → /var/lib/hyperion-id mounts in stage-1 initrd (neededForBoot = true)
  → activationScripts.hyperionIdentitySchemaCheck verifies meta/schema-version="2"
  → sops-nix decrypts /run/secrets/* using per-node age key from USB
  → apply-identity.service stages /run/hyperion/identity.env (hostname, IP)
  → services.k3s.agent registers with Monolith server at 192.168.10.247:6443
  → services.journald.upload ships to Heimdall :19532

Day-2 changes (no NVMe re-flash):
  Workstation: cd Hyperion/nixos && colmena apply --on hyperion-<greek>
  → nix-copy-closure to target → nixos-rebuild switch → done
```

**Key NixOS invariants:**

- **One closure per host, not one across the cluster.** Per-host divergence (k3s nodeLabel/nodeTaint, optional Pi 5 overrides) lives in `Hyperion/nixos/hosts/<hostname>.nix` evaluated at build time. Identity USB carries only runtime metadata (hostname, IP, age key, SSH host keys).
- **`services.k3s.{nodeLabel,nodeTaint}` are first-class options** (per nixpkgs release-25.11). Do NOT wrap `systemd.services.k3s.serviceConfig.ExecStart` with `lib.mkForce` — that pattern was rejected during pipeline iter-2 (IAC-1 NAY).
- **`fileSystems."/var/lib/hyperion-id".neededForBoot = true` is non-negotiable.** Without it sops-nix activation can fire before the USB mount and fail to decrypt.
- **Pi 5 config.txt directives must be added explicitly** via `hardware.raspberry-pi.config.all = { options = ...; base-dt-params = ...; }`. The `nvmd/nixos-raspberrypi` flake auto-emits only `enable_uart=1` and selects the rpi5 kernel + nvme initrd module. Everything else (auto_initramfs, usb_max_current_enable, dtparam=nvme, dtparam=pciex1_gen=3) is operator-supplied.
- **No `kernel=kernel_2712.img` directive.** The `kernelboot` builder stages the kernel as literal `kernel.img`; the Pi 5 EEPROM (BCM2712) boots it by default. The `kernel_2712.img` filename is a Debian/Pi-OS convention.
- **Rollback under `bootloader = "kernelboot"` has NO boot-time menu.** Recovery from a broken generation requires installer-SD boot to manually re-stage a previous kernel.img. See `Hyperion/docs/runbooks/rollback-a-node.md`. Switching to `bootloader = "uboot"` provides an extlinux menu but is less-traveled on Pi 5.
- **Pin `nvmd/nixos-raspberrypi` by tag.** Predecessor `nix-community/raspberry-pi-nix` was archived 2025-03-23 with Pi 5 USB/NVMe boot listed under "What's not working." Current pin: `v1.20260517.0`.
- **k3s worker-server skew:** nixpkgs release-25.11 ships k3s 1.34.5; Monolith runs 1.35.3. Within k3s's N-1 supported window. If Monolith bumps to 1.36+, override `services.k3s.package`.

### Debian/Packer architecture (sunsetting 2026-08-15)

Files: `Hyperion/packer/`, `Hyperion/bootstrap.sh`, `Hyperion/ansible/`, `Hyperion/reimage.sh`, `Hyperion/watch-flash.sh`, `Hyperion/publish-image.sh`.

```
GitHub push (Hyperion/packer/**, main)
  → CI builds image with Packer (now native ubuntu-24.04-arm, Phase 0 cutover)
  → Publishes to GitHub Releases (tags: node-v<EPOCH>, bootstrap-latest)

Heimdall ci-deploy (polls GitHub every 5 min)
  → Downloads release asset → decompresses → places under /opt/Homelab/Heimdall/hyperion/images/{node,bootstrap}/
  → nginx (192.168.10.4:50011) serves to the LAN

Pi node boot (BOOT_ORDER=0xf641 → SD → USB → NVMe → loop)
  ├── Bootstrap media inserted → Bootstrap IMG runs
  │     1. Reads identity from HYPERION-ID USB (per-node hostname + image cache)
  │     2. If Heimdall reachable AND has newer Node IMG → updates USB cache
  │     3. If USB cache version > NVMe version → dd USB → NVMe → repartition → reboot
  │     4. Else → reboot into NVMe
  └── No bootstrap media → boots straight into NVMe (Node IMG / production)
```

**The Debian path's reflash mechanism is what the pivot is sidestepping.** Per the user's 00b correction in the pipeline run, "despite many, many different tries no matter what we do the SSDs aren't getting reflashed." The NixOS pivot replaces this entire mechanism with workstation-`dd`-once + Colmena-push-from-then-on.

**Debian invariants that remain:**

- USB-authoritative imaging (network → USB cache → NVMe; never network → NVMe directly).
- Identity travels on HYPERION-ID USB, not on hardware.
- Bootstrap SD is identical across all 10 nodes.
- EEPROM (`BOOT_ORDER=0xf641`) is per-Pi-and-permanent in SPI flash.
- Bootstrap has `MAX_BOOT_ATTEMPTS=3` boot-loop protection.

### Bridging the two architectures

- **Identity USB shape is different.** The Debian path's HYPERION-ID is exFAT with a `/hostname` file and `/node-image/` cache directory. The NixOS path's HYPERION-ID is ext4 (schema version 2) with `/identity.env`, `/age-key.txt`, `/secrets/`, `/meta/`. `flash-identity-usb.sh` was rewritten for the NixOS schema — operators flashing a USB now produce the NixOS shape. The old Debian USBs continue to work on Debian-imaged nodes until they're re-flashed.
- **`configure-eeprom.sh` is KEEP under both paths.** EEPROM is below the OS layer.
- **The image-server at `192.168.10.4:50011` is shared.** It hosts both Debian images (`/node/`, `/bootstrap/`) and NixOS installer images (`/nvme/`).

## Common commands

```bash
# ─── NixOS (forward path) ────────────────────────────────────────────────────
cd Hyperion/nixos

# Build the installer image (or use CI)
nix build .#installerImage

# Build a specific node's complete closure (for inspection)
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel

# Push day-2 changes from workstation
colmena apply --on hyperion-alpha
colmena apply --on '@hyperion-*' --parallel 4

# Update nixpkgs / nixos-raspberrypi pins
nix flake update --input nixpkgs --input nixos-raspberrypi

# ─── Cross-architecture (kept under both paths) ──────────────────────────────
cd Hyperion

# Per-node identity USB (NixOS schema v2)
./flash-identity-usb.sh /dev/sdX hyperion-alpha

# EEPROM boot order (one-time per Pi, OS-agnostic)
./configure-eeprom.sh --user owner --reboot               # all 10 nodes
./configure-eeprom.sh hyperion-alpha --user owner --reboot

# ─── Debian (sunsetting 2026-08-15) ──────────────────────────────────────────
# Build + publish images locally
export NODE_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./publish-image.sh node                # builds, zstd -19, creates GitHub Release node-v<EPOCH>
./publish-image.sh bootstrap

# Re-image (Bootstrap SD/USB must be physically inserted first)
./reimage.sh hyperion-alpha
./reimage.sh all

# Live monitor flashing
./watch-flash.sh hyperion-alpha

# Post-imaging configuration
cd ansible && ansible-playbook -i inventory.yaml bootstrap.yml
```

CI is triggered on push to `main`:
- `Hyperion/packer/**` → Debian Bootstrap IMG + Node IMG (Phase 0: now native ubuntu-24.04-arm)
- `Hyperion/nixos/**` → NixOS installer image (native ubuntu-24.04-arm)
- All three use `concurrency: build-images` to serialize.

## Secrets

SOPS + age — but the model differs between Debian and NixOS:

**Debian path:** one workstation age key (`~/.config/sops/age/keys.txt`). `Hyperion/.sops.yaml` lists the public half. Secrets at `Hyperion/k8s/.../secret*.yaml`.

**NixOS path:** **per-node age keys.** Each Pi has its own age private key on its HYPERION-ID USB. `Hyperion/.sops.yaml` lists all 10 per-node public keys + the operator's public key. Secrets at `Hyperion/nixos/secrets/common.yaml` are encrypted to all 10 + operator. sops-nix decrypts at activation time using the USB-resident key.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>

# When adding a node, the printed age public key from flash-identity-usb.sh
# must be added to Hyperion/.sops.yaml and re-encrypted:
cd Hyperion && sops updatekeys nixos/secrets/common.yaml
```

The only required GitHub Actions secret is `NODE_SSH_PUBLIC_KEY` (used by the Debian Packer build); CI uses the auto-provided `GITHUB_TOKEN` for releases.

## Network reference

Single VLAN `192.168.10.0/24`. UCG (`.1`) is the DHCP server.

| Range | Purpose |
|-------|---------|
| `.4` | Heimdall (Caddy, Technitium, Komodo, Hyperion-flashing-stack) |
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion nodes (alpha → kappa, in Greek-letter order) |
| `.247` | Monolith (k3s server `:6443`, healthcheck `:50012`) |

Heimdall hyperion-stack ports: nginx `:50011` (images), journal-remote `:19532` (upload sink), journal-gatewayd `:19531` (HTML browse). Bootstrap status endpoint `:8080` per-Pi (Debian path only).

## When you change something

- **`Hyperion/nixos/**`** → CI rebuilds the installer image. Push via Colmena for day-2 changes. See `Hyperion/docs/runbooks/deploy-via-colmena.md`.
- **`Hyperion/nixos/hosts/<hostname>.nix`** → only that host's closure rebuilds. `colmena apply --on <hostname>`.
- **`Hyperion/.sops.yaml`** → re-encrypt all secrets: `sops updatekeys nixos/secrets/common.yaml`.
- **`Hyperion/packer/**`** (Debian, still tracked until sunset) → CI rebuilds the relevant Packer image. Same `concurrency: build-images`.
- **`Hyperion/configure-eeprom.sh`** → re-run against affected nodes; not auto-deployed.
- **`Monolith/k3s-control-plane/docker-compose.yml`** → not auto-deployed. Re-run `docker compose up -d` on Monolith manually.
- **`Heimdall/hyperion/`** → see `Heimdall/docs/runbooks/flashing-services.md`. Currently operator-deployed via Komodo or `docker compose pull`.
- **k8s manifests under `Hyperion/k8s/`** → reconciled by FluxCD (when bootstrapped — currently TODO).

## Pipeline-run records (decision history)

Two completed DEVELOPMENT pipelines and one DEBUGGING pipeline live under `docs/pipeline-runs/` locally (gitignored):

- `20260504T000719Z-dbg-nvme-not-flashing/` — six-hypothesis catalog for the Debian-path reflash failure; conclusion was iterated-on extensively but never closed empirically (per the 00b correction in the later NixOS pipeline).
- `20260517T...-dev-heimdall-*` — Heimdall stack design (Caddy + Technitium + Komodo) and the subsequent migration of Hyperion flashing services to Heimdall.
- `20260523T050133Z-dev-nixos-identity-usb/` — this pivot. FINAL.md is the orienting document; iter-2/04-revision.md is the latest binding text.

The agent-notes Settled-knowledge sections under `docs/agent-notes/*.md` carry the durable Pi/Linux/Hyperion facts that survive each pipeline.
