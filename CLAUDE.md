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

## Hyperion architecture — NixOS, validated and in production

The single most important thing to know about Hyperion: **it runs NixOS**. The pivot from Debian/Packer to NixOS is complete and hardware-validated — all 10 Pi 5 workers are NixOS-on-NVMe and `Ready` on the k3s control plane (validated 2026-06-01). The legacy Debian/Packer stack still coexists in-tree, but only as a fallback until the 2026-08-15 sunset gate. The pivot was approved by a 6-YAE / 0-NAY vote across 2 iterations of the standing-team DEVELOPMENT pipeline (run `20260523T050133Z-dev-nixos-identity-usb/`, FINAL.md lives in the run folder locally per `.gitignore`).

### NixOS architecture (the forward path) — HARDWARE-VALIDATED 2026-06-01

Files: `Hyperion/nixos/` + `Hyperion/setup-hyperion-node.sh` + `Hyperion/inventory.yaml`.
Nodes have been flashed to NixOS-on-NVMe and joined the Heimdall k3s control
plane (`Ready`, v1.34.5+k3s1). **The authoritative runbook is
`Hyperion/docs/runbooks/turnkey-node-setup.md`; the per-node command is
`setup-hyperion-node.sh`.**

**The as-built flow uses a stock Raspberry-Pi-OS bootstrap SD (NOT a NixOS SD
installer), driven entirely over SSH by `setup-hyperion-node.sh`:**

```
Per node (the ONLY hands-on): move the single stock RasPi-OS SD (user pi /
  password raspberry, SSH on) into the Pi, power on. The NVMe is a SEPARATE disk.

Workstation (.10 VLAN):  ./setup-hyperion-node.sh --name hyperion-<greek>
  Phase 0  preflight (name<->host, IP from inventory.yaml, tools, operator age key)
  Phase 1  install workstation key + NOPASSWD sudo on the bootstrap (pi)
  Phase 2  register-node-key.sh: per-node age + SSH host keys, add to .sops.yaml,
           re-encrypt common.yaml   (flock-guarded; --no-register for parallel runs)
  Phase 3  install Determinate Nix on the bootstrap; set substituters
           (cache.nixos.org + nixos-raspberrypi.cachix.org); rsync the flake;
           stage the decrypted secret tree
  Phase 4  disko-install: partition /dev/nvme0n1 + build/substitute the
           hyperion-<greek> closure + inject age key + SSH host keys.
           THEN finish the bootloader via nixos-enter (sops mount gotcha, below)
  Phase 5  EEPROM BOOT_ORDER=0xf416 (NVMe -> SD -> USB -> loop); reboot
  Phase 6  verify NixOS boot + sops-decrypted k3s token + k3s active, then
           confirm the node reaches Ready from the Heimdall control plane

  → services.k3s.agent registers with Heimdall at 192.168.10.4:6443
  → node IP is the UCG DHCP reservation BY MAC. Name<->IP per inventory.yaml;
    flash each node by the IP it actually comes up on (the script auto-resolves
    --ip from inventory by name). Power-on order != IP order.

Why no kexec / no SD installer: kexec is dead on these Pis (/proc/kcore absent),
but the NVMe is a SEPARATE disk from the boot SD — so there is no same-disk
chicken-and-egg. We install onto the NVMe from the running RasPi-OS bootstrap.

Day-2 changes (no NVMe re-flash):
  cd Hyperion/nixos && colmena apply --on hyperion-<greek>   (needs Nix on the
  workstation; the flash path does not).
```

**SUPERSEDED (kept in-tree, do NOT use for new nodes):** the CI-built live SD
installer (`packages.installerSdImage`) + `flash-node.sh` (nixos-anywhere
`--phases disko,install,reboot`) + `docs/runbooks/remote-flash-a-node.md`. That
path assumed booting a NixOS SD installer per node; the validated path uses the
stock RasPi-OS SD + `disko-install` instead. ADR-0001 still records the
kexec/remote-flash rationale.

**Two install gotchas (both handled by the script — see the runbook):**
- **sops-nix `mount` not on PATH** during the offline `disko-install` activation
  aborts *before* the kernelboot install (empty `/boot/firmware` → won't boot).
  The script finishes with `nixos-enter … switch-to-configuration boot` with
  util-linux on PATH.
- **The Pi kernel disables the memory cgroup by default** → k3s dies with
  "failed to find memory cgroup (v2)". Fixed in `hyperion-base.nix`
  `boot.kernelParams` (`cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1`).

**Key NixOS invariants:**

- **One closure per host, not one across the cluster.** Per-host divergence (hostname via `networking.hostName`, k3s nodeLabel/nodeTaint, optional Pi 5 overrides) lives in `Hyperion/nixos/hosts/<hostname>.nix` evaluated at build time. Node IP is the UCG DHCP reservation.
- **`services.k3s.{nodeLabel,nodeTaint}` are first-class options** (per nixpkgs release-25.11). Do NOT wrap `systemd.services.k3s.serviceConfig.ExecStart` with `lib.mkForce` — that pattern was rejected during pipeline iter-2 (IAC-1 NAY).
- **Secrets are injected at install, not carried on a USB.** `setup-hyperion-node.sh` passes the per-node sops age key (`/var/lib/sops-nix/key.txt`) and SSH host keys (`/etc/ssh/`) to `disko-install --extra-files` — never in git or the Nix store. The retired HYPERION-ID USB model (stage-1 `neededForBoot` mount, `apply-identity.service`, schema-version check) is gone; see ADR-0001. **The HYPERION-ID USB drives are now inert and physically removable** — no NixOS node mounts or depends on them (verified 2026-06-01).
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

- **The NixOS path no longer uses an identity USB at all.** The Debian path still uses its exFAT HYPERION-ID; the NixOS path injects secrets at install via `setup-hyperion-node.sh` → `disko-install --extra-files`. The HYPERION-ID USBs are inert/removable for NixOS nodes (verified 2026-06-01). The two paths share no removable-media identity.
- **`configure-eeprom.sh` logic is KEEP under both paths** (EEPROM is below the OS layer), but `setup-hyperion-node.sh` sets the EEPROM itself over SSH rather than calling that script. Debian uses `BOOT_ORDER=0xf641`; **NixOS uses `0xf416` (NVMe → SD → USB → loop)** — a blank/old NVMe falls through to the inserted bootstrap SD; an installed NVMe wins and the SD is ignored.
- **The image-server at `192.168.10.4:50011` is shared** (Debian images). The validated NixOS flash builds the closure on the node from cache; it does not pull an SD-installer image from the LAN.

## Common commands

```bash
# ─── NixOS (forward path) — VALIDATED ────────────────────────────────────────
cd Hyperion

# Flash one node end-to-end (RasPi-OS bootstrap inserted + powered first).
# Runs register-keys -> Nix-on-bootstrap -> disko-install -> EEPROM 0xf416 ->
# reboot -> verify Ready. IP auto-resolves from inventory.yaml by name.
# See docs/runbooks/turnkey-node-setup.md.
./setup-hyperion-node.sh --name hyperion-alpha                 # --ip optional
./setup-hyperion-node.sh --name hyperion-beta --yes            # skip wipe prompt

# Parallel (needs one bootstrap SD per node): pre-register serially, then fan out
for g in eta iota kappa; do ./register-node-key.sh hyperion-$g; done && git commit -am 'register ...'
./setup-hyperion-node.sh --name hyperion-eta  --yes --no-register &
./setup-hyperion-node.sh --name hyperion-iota --yes --no-register &

# Build a specific node's complete closure (for inspection; needs Nix)
cd nixos && nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel

# Push day-2 changes from workstation (needs Nix on the workstation)
colmena apply --on hyperion-alpha
colmena apply --on '@hyperion-*' --parallel 4
# No-Nix alternative for an existing node: rsync nixos/ to it + run on the node:
#   sudo nixos-rebuild switch --flake /home/owner/hyperion-nixos#hyperion-alpha

# Update nixpkgs / nixos-raspberrypi pins
nix flake update --input nixpkgs --input nixos-raspberrypi

# ─── Cross-architecture (kept under both paths) ──────────────────────────────
cd Hyperion
# NixOS nodes use 0xf416 (NVMe → SD → USB → loop) — set automatically by
# setup-hyperion-node.sh. configure-eeprom.sh is the standalone/Debian tool:
./configure-eeprom.sh hyperion-alpha --user pi --boot-order 0xf416 --reboot
./configure-eeprom.sh --user owner --reboot               # Debian default 0xf641

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
| `.4` | Heimdall (Caddy, Technitium, Authentik, cloudflared, Komodo, Hyperion-flashing-stack, k3s control plane) |
| `.10–.99` | MetalLB LoadBalancer pool (~30 cluster services) |
| `.101–.110` | Hyperion nodes (alpha → kappa, in Greek-letter order) |
| `.144` | Thoth (GPU compute host — Ubuntu Server, 2× RTX 6000 Ada; Docker Compose via Komodo Periphery) |
| `.180` | APC AP7900 PDU (switched, 8 outlets; Telnet CLI on `:23`, no SSH/HTTPS) |
| `.247` | Akasha (TrueNAS Scale; pure-storage role, NFS exports to the cluster) |

Off-VLAN: **Epsilon** (`192.168.0.105`, Pop!_OS workstation, RTX 4080) runs a Tdarr GPU transcode worker on the main home subnet.

Heimdall ports: k3s API `:6443`, Flannel VXLAN `:8472/udp`, nginx `:50011` (images), journal-remote `:19532` (upload sink), journal-gatewayd `:19531` (HTML browse). Bootstrap status endpoint `:8080` per-Pi (Debian path only).

**k3s control-plane caveat (important):** the control plane runs in a *bridge-networked* Docker container on Heimdall, so its flannel VTEP (`172.19.0.2`) is unreachable from the Pi workers. Consequences (until it's relocated off Heimdall — the planned next step): the control-plane node is tainted `node.homelab/control-plane-only:NoExecute` (**all k8s app workloads must `nodeSelector topology.kubernetes.io/zone=hyperion`**); `kubectl top`/metrics-server is broken; the metallb controller is pinned onto the control-plane node for webhook reachability. Full rationale + the load-bearing `--advertise-address`/`--node-taint` server flags: `docs/design/adr-0002-containerized-control-plane-networking.md` and `Heimdall/k3s-control-plane/README.md`.

GitOps: FluxCD (read-only, no token) reconciles `Hyperion/k8s/`; MetalLB serves the `.10–.99` LoadBalancer pool. See `Hyperion/k8s/README.md`.

## When you change something

- **`Hyperion/nixos/**`** → CI rebuilds the installer image. Push via Colmena for day-2 changes. See `Hyperion/docs/runbooks/deploy-via-colmena.md`.
- **`Hyperion/nixos/hosts/<hostname>.nix`** → only that host's closure rebuilds. `colmena apply --on <hostname>`.
- **`Hyperion/.sops.yaml`** → re-encrypt all secrets: `sops updatekeys nixos/secrets/common.yaml`.
- **`Hyperion/packer/**`** (Debian, still tracked until sunset) → CI rebuilds the relevant Packer image. Same `concurrency: build-images`.
- **`Hyperion/configure-eeprom.sh`** → re-run against affected nodes; not auto-deployed.
- **`Heimdall/k3s-control-plane/`** → not auto-deployed. Re-run `bash Heimdall/scripts/deploy.sh` from the workstation (ships both env secrets + restarts the stack). See `Heimdall/k3s-control-plane/README.md`.
- **`Heimdall/hyperion/`** → same deploy script; see `Heimdall/docs/runbooks/flashing-services.md`.
- **k8s manifests under `Hyperion/k8s/`** → reconciled by FluxCD (live since 2026-06-01; read-only, no token). Push to `origin/main` — Flux reads GitHub, not your working tree.

## Pipeline-run records (decision history)

Two completed DEVELOPMENT pipelines and one DEBUGGING pipeline live under `docs/pipeline-runs/` locally (gitignored):

- `20260504T000719Z-dbg-nvme-not-flashing/` — six-hypothesis catalog for the Debian-path reflash failure; conclusion was iterated-on extensively but never closed empirically (per the 00b correction in the later NixOS pipeline).
- `20260517T...-dev-heimdall-*` — Heimdall stack design (Caddy + Technitium + Komodo) and the subsequent migration of Hyperion flashing services to Heimdall.
- `20260523T050133Z-dev-nixos-identity-usb/` — this pivot. FINAL.md is the orienting document; iter-2/04-revision.md is the latest binding text.

The agent-notes Settled-knowledge sections under `docs/agent-notes/*.md` carry the durable Pi/Linux/Hyperion facts that survive each pipeline.
