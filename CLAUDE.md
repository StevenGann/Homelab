# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Convention

Top-level directories map to **physical hosts or clusters**:

- `Hyperion/` — the 10-node Raspberry Pi 5 k3s worker cluster
- `Heimdall/` — edge-services host at `192.168.10.4` (Caddy reverse proxy, Technitium DNS, Komodo container manager; **also hosts the Hyperion flashing services** moved from Akasha on 2026-05-21 and the **k3s control plane** moved from Akasha on 2026-05-24)
- `Akasha/` — the TrueNAS Scale host at `192.168.10.247`. Formerly Monolith; renamed and being renovated to a pure-storage role once Hyperion is operational. The old broken k3s control plane was deleted 2026-05-24 — currently no tracked code under `Akasha/`.
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
  → CI builds the live SD installer image via nix on ubuntu-24.04-arm (5-25 min)
  → Publishes to GitHub Releases (tag: sd-installer-<datestamp>-<sha>)

Heimdall ci-deploy (polls GitHub every 5 min — moved from Akasha 2026-05-21)
  → Downloads release asset to /opt/Homelab/Heimdall/hyperion/images/sd-installer/
  → nginx (192.168.10.4:50011) serves to the LAN

One-time per node, at hardware assembly (the ONLY hands-on):
  Flash the SD installer (identical for all 10) to a microSD, insert it
  Set EEPROM BOOT_ORDER=0xf16 (NVMe → SD → loop): blank NVMe falls through
    to the SD installer; an installed NVMe wins and the SD is ignored
  Assign the node a UCG DHCP reservation (.101..110)

Remote install (operator-driven, from the workstation — see
docs/runbooks/remote-flash-a-node.md):
  ./register-node-key.sh hyperion-<greek>     # once: gen + register keys, commit
  Power on with a blank NVMe → boots the SD installer, SSH-reachable
  ./flash-node.sh <ip> hyperion-<greek>
    → nixos-anywhere (kexec SKIPPED — broken on Pi; phases disko,install,reboot)
    → disko partitions /dev/nvme0n1 from the host closure
    → per-host closure built ON the node (--build-on-remote, Cachix-substituted)
    → age key + SSH host keys injected via --extra-files (no USB, no Nix store)
    → node reboots; EEPROM now finds the NVMe and boots NixOS
  → services.k3s.agent registers with Heimdall control plane at 192.168.10.4:6443
  → services.journald.upload ships to Heimdall :19532

Day-2 changes (no NVMe re-flash):
  Workstation: cd Hyperion/nixos && colmena apply --on hyperion-<greek>
  → nix-copy-closure to target → nixos-rebuild switch → done
```

**Key NixOS invariants:**

- **One closure per host, not one across the cluster.** Per-host divergence (hostname via `networking.hostName`, k3s nodeLabel/nodeTaint, optional Pi 5 overrides) lives in `Hyperion/nixos/hosts/<hostname>.nix` evaluated at build time. Node IP is the UCG DHCP reservation.
- **`services.k3s.{nodeLabel,nodeTaint}` are first-class options** (per nixpkgs release-25.11). Do NOT wrap `systemd.services.k3s.serviceConfig.ExecStart` with `lib.mkForce` — that pattern was rejected during pipeline iter-2 (IAC-1 NAY).
- **Secrets are injected at install, not carried on a USB.** `nixos-anywhere --extra-files` places the per-node sops age key at `/var/lib/sops-nix/key.txt` and SSH host keys at `/etc/ssh/` — never in git or the Nix store. The retired HYPERION-ID USB model (stage-1 `neededForBoot` mount, `apply-identity.service`, schema-version check) is gone; see ADR-0001 (`docs/design/adr-0001-nixos-anywhere-remote-flash.md`). kexec is broken on the Pi, so installs run from a live SD installer with `--phases disko,install,reboot`.
- **Pi 5 config.txt directives must be added explicitly** via `hardware.raspberry-pi.config.all = { options = ...; base-dt-params = ...; }`. The `nvmd/nixos-raspberrypi` flake auto-emits only `enable_uart=1` and selects the rpi5 kernel + nvme initrd module. Everything else (auto_initramfs, usb_max_current_enable, dtparam=nvme, dtparam=pciex1_gen=3) is operator-supplied.
- **No `kernel=kernel_2712.img` directive.** The `kernelboot` builder stages the kernel as literal `kernel.img`; the Pi 5 EEPROM (BCM2712) boots it by default. The `kernel_2712.img` filename is a Debian/Pi-OS convention.
- **Rollback under `bootloader = "kernelboot"` has NO boot-time menu.** Recovery from a broken generation requires installer-SD boot to manually re-stage a previous kernel.img. See `Hyperion/docs/runbooks/rollback-a-node.md`. Switching to `bootloader = "uboot"` provides an extlinux menu but is less-traveled on Pi 5.
- **Pin `nvmd/nixos-raspberrypi` by tag.** Predecessor `nix-community/raspberry-pi-nix` was archived 2025-03-23 with Pi 5 USB/NVMe boot listed under "What's not working." Current pin: `v1.20260517.0`.
- **k3s worker-server alignment:** the Heimdall control plane runs `rancher/k3s:v1.34.5-k3s1` (pinned in `Heimdall/k3s-control-plane/docker-compose.yml`), matching what nixpkgs nixos-25.11 ships for workers. Same-minor — no skew workarounds needed. Bump server + workers in lockstep when nixpkgs rolls a newer k3s.

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

- **The NixOS path no longer uses an identity USB at all.** The Debian path still uses its exFAT HYPERION-ID (`/hostname` + `/node-image/` cache). The NixOS path injects secrets at install via `nixos-anywhere --extra-files` (`register-node-key.sh` + `flash-node.sh`); `flash-identity-usb.sh` is deprecated. The two paths share no removable-media identity.
- **`configure-eeprom.sh` is KEEP under both paths.** EEPROM is below the OS layer. Debian uses `BOOT_ORDER=0xf641`; NixOS uses `0xf16` (NVMe → SD installer fallback).
- **The image-server at `192.168.10.4:50011` is shared.** It hosts Debian images (`/node/`, `/bootstrap/`) and the NixOS live SD installer (`/sd-installer/`).

## Common commands

```bash
# ─── NixOS (forward path) ────────────────────────────────────────────────────
cd Hyperion/nixos

# Build the live SD installer image (or use CI)
nix build .#installerSdImage

# Build a specific node's complete closure (for inspection)
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel

# Remotely flash a node (see docs/runbooks/remote-flash-a-node.md)
cd Hyperion
./register-node-key.sh hyperion-alpha            # once per node, then commit
./flash-node.sh 192.168.10.101 hyperion-alpha    # node booted into the SD installer
cd nixos

# Push day-2 changes from workstation
colmena apply --on hyperion-alpha
colmena apply --on '@hyperion-*' --parallel 4

# Update nixpkgs / nixos-raspberrypi pins
nix flake update --input nixpkgs --input nixos-raspberrypi

# ─── Cross-architecture (kept under both paths) ──────────────────────────────
cd Hyperion

# EEPROM boot order (one-time per Pi, OS-agnostic)
# NixOS nodes: 0xf16 (NVMe → SD installer fallback)
./configure-eeprom.sh hyperion-alpha --user owner --boot-order 0xf16 --reboot
# Debian nodes (sunsetting): default 0xf641
./configure-eeprom.sh --user owner --reboot               # all 10 nodes

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
- `Hyperion/nixos/**` → live SD installer image (native ubuntu-24.04-arm); also eval-checks a worker closure. Release published on `main` only; manual/feature-branch `workflow_dispatch` runs build without publishing.
- All three use `concurrency: build-images` to serialize.

## Secrets

SOPS + age — but the model differs between Debian and NixOS:

**Debian path:** one workstation age key (`~/.config/sops/age/keys.txt`). `Hyperion/.sops.yaml` lists the public half. Secrets at `Hyperion/k8s/.../secret*.yaml`.

**NixOS path:** **per-node age keys.** Each Pi has its own age private key, generated workstation-side by `register-node-key.sh`, stored age-encrypted to the operator in `Hyperion/nixos/node-keys/<host>.tar.age` (committed), and injected onto the node's NVMe at `/var/lib/sops-nix/key.txt` by `nixos-anywhere --extra-files` at install. `Hyperion/.sops.yaml` lists the registered per-node public keys + the operator's. Secrets at `Hyperion/nixos/secrets/common.yaml` are encrypted to all registered nodes + operator. sops-nix decrypts at activation time using the on-NVMe key.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>

# Adding a node: register-node-key.sh generates the key, adds the pubkey to
# Hyperion/.sops.yaml, and re-encrypts common.yaml in one step:
cd Hyperion && ./register-node-key.sh hyperion-<greek>
```

The only required GitHub Actions secret is `NODE_SSH_PUBLIC_KEY` (used by the Debian Packer build); CI uses the auto-provided `GITHUB_TOKEN` for releases.

## Network reference

Single VLAN `192.168.10.0/24`. UCG (`.1`) is the DHCP server.

| Range | Purpose |
|-------|---------|
| `.4` | Heimdall (Caddy, Technitium, Komodo, Hyperion-flashing-stack, k3s control plane) |
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion nodes (alpha → kappa, in Greek-letter order) |
| `.247` | Akasha (TrueNAS Scale; renovating to pure storage) |

Heimdall ports: k3s API `:6443`, Flannel VXLAN `:8472/udp`, nginx `:50011` (images), journal-remote `:19532` (upload sink), journal-gatewayd `:19531` (HTML browse). Bootstrap status endpoint `:8080` per-Pi (Debian path only).

## When you change something

- **`Hyperion/nixos/**`** → CI rebuilds the installer image. Push via Colmena for day-2 changes. See `Hyperion/docs/runbooks/deploy-via-colmena.md`.
- **`Hyperion/nixos/hosts/<hostname>.nix`** → only that host's closure rebuilds. `colmena apply --on <hostname>`.
- **`Hyperion/.sops.yaml`** → re-encrypt all secrets: `sops updatekeys nixos/secrets/common.yaml`.
- **`Hyperion/packer/**`** (Debian, still tracked until sunset) → CI rebuilds the relevant Packer image. Same `concurrency: build-images`.
- **`Hyperion/configure-eeprom.sh`** → re-run against affected nodes; not auto-deployed.
- **`Heimdall/k3s-control-plane/`** → not auto-deployed. Re-run `bash Heimdall/scripts/deploy.sh` from the workstation (ships both env secrets + restarts the stack). See `Heimdall/k3s-control-plane/README.md`.
- **`Heimdall/hyperion/`** → same deploy script; see `Heimdall/docs/runbooks/flashing-services.md`.
- **k8s manifests under `Hyperion/k8s/`** → reconciled by FluxCD (when bootstrapped — currently TODO).

## Pipeline-run records (decision history)

Two completed DEVELOPMENT pipelines and one DEBUGGING pipeline live under `docs/pipeline-runs/` locally (gitignored):

- `20260504T000719Z-dbg-nvme-not-flashing/` — six-hypothesis catalog for the Debian-path reflash failure; conclusion was iterated-on extensively but never closed empirically (per the 00b correction in the later NixOS pipeline).
- `20260517T...-dev-heimdall-*` — Heimdall stack design (Caddy + Technitium + Komodo) and the subsequent migration of Hyperion flashing services to Heimdall.
- `20260523T050133Z-dev-nixos-identity-usb/` — this pivot. FINAL.md is the orienting document; iter-2/04-revision.md is the latest binding text.

The agent-notes Settled-knowledge sections under `docs/agent-notes/*.md` carry the durable Pi/Linux/Hyperion facts that survive each pipeline.
