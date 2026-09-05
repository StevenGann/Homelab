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

`README.md` is the authoritative entry point. `docs/todo.md` tracks operational state. For current state, **read the code and `Hyperion/docs/runbooks/`**.

**Known-stale documents — do NOT follow them for current behavior:**

- `docs/hyperion-iac-plan.md` and the body of `docs/design/node-image-approach.md` — archived/obsolete.
- `Hyperion/docs/network-layout.md` and `Heimdall/docs/network-layout.md` — both carry a stale-header now; the live map is in `CLAUDE.md` §Network reference and `README.md` §Network.
- `Akasha/docs/runbooks/nfs-media-export.md` — documents a **single-export `/data`** design that was never built. The as-built is one export per media category; see the header note in that file and `Hyperion/k8s/apps/media/00-storage/`.
- `docs/dr-readiness-2026-07-04.md` — a point-in-time audit. Several findings (the six orphan Flux workloads, the komga/nextcloud `.82` collision, ddns-updater capture) have since been fixed.

**Live state was verified end-to-end on 2026-09-05.** 10/10 Pi workers `Ready` on NixOS 25.11 / k3s v1.34.5+k3s1; 31 Flux Kustomizations all `Ready` at `main`; 46 LoadBalancer Services. Deviations found in that sweep are recorded in `README.md` §Status and `docs/todo.md`.

## Hyperion architecture — NixOS, validated and in production

The single most important thing to know about Hyperion: **it runs NixOS**. The pivot from Debian/Packer to NixOS is complete and hardware-validated — all 10 Pi 5 workers are NixOS-on-NVMe and `Ready` on the k3s control plane (validated 2026-06-01). The legacy Debian/Packer stack still sits in-tree, but it is **dead**: its 2026-08-15 sunset gate passed with no action, `Hyperion/retired/` was never created, and the `Heimdall/hyperion/` stack that served its images is not running. Treat it as deletable, not as a fallback. The pivot was approved by a 6-YAE / 0-NAY vote across 2 iterations of the standing-team DEVELOPMENT pipeline (run `20260523T050133Z-dev-nixos-identity-usb/`, FINAL.md lives in the run folder locally per `.gitignore`).

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

### Debian/Packer architecture (DEAD — sunset gate lapsed 2026-08-15, files not yet removed)

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

# ─── Debian (DEAD — sunset gate lapsed 2026-08-15; kept only until deleted) ──
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
| `.1` | UCG gateway / DHCP server |
| `.4` | Heimdall (Pi-hole, Technitium, Caddy, ddns-updater, Komodo+mongo, k3s control plane) |
| `.10–.99` | MetalLB LoadBalancer pool (46 LoadBalancer Services live as of 2026-09-05) |
| `.101–.110` | Hyperion nodes (alpha → kappa, in Greek-letter order) |
| `.144` | Thoth (GPU compute host — 2× RTX 6000 Ada; Docker Compose via Komodo Periphery) — **POWERED OFF, services suspended pending hardware changes** |
| `.147` | Home Assistant (`:8123`) — consumes the `Sensors/` MQTT feed; not IaC-tracked |
| `.180` | APC AP7900 PDU (switched, 8 outlets; Telnet CLI on `:23`, no SSH/HTTPS) |
| `.201` | Synology NAS (`:5000`) — not IaC-tracked |
| `.230` | **owner-thinkpad** — operator workstation. Holds the operator SSH key + nix/sops/colmena. **Use it as the jump box for Heimdall.** |
| `.231` | HDHomeRun tuner — not IaC-tracked |
| `.247` | Akasha (TrueNAS Scale 25.04.2; storage + the LAN Jellyfin at NodePort `:30013`) |

Unidentified but pingable: `.179`, `.191`, `.241`, `.254`.

Off-VLAN: **Epsilon** (`192.168.0.105`, hostname `WS-EPSILON`, Ubuntu 26.04, RTX 4080) on the main home subnet. It historically ran a Tdarr GPU worker; that worker is **not running** (no container runtime installed).

**Reaching the lab from `192.168.0.0/24` (e.g. Epsilon):** ICMP, HTTP/80 to the MetalLB pool, DNS to `.4:53`, `.4:443`, `.4:6443`, and SSH to the Pi nodes and Akasha all work. **SSH to Heimdall (`.4:22`) is blocked from that subnet** — go through `owner-thinkpad` (`.230`) as a `ProxyJump`. Akasha's sshd refuses TCP forwarding, so it does not work as a jump host.

**DNS is two-stage:** **Pi-hole owns `0.0.0.0:53`** on Heimdall and does the ad/malware filtering; it conditionally forwards the `.lab` zone to **Technitium** (`server=/lab/127.0.0.1#5353`, in `Heimdall/pihole/etc-dnsmasq.d/02-lan.conf`). Technitium is authoritative for `.lab` only and is bound to localhost (`:5353` DNS, `:5380` UI). Do not describe Technitium as the LAN resolver.

Heimdall ports actually bound: `:22` (SSH, LAN-local), `:53` (Pi-hole), `:80`/`:443`/`:7443` (Caddy), `:6443` (k3s API), `:8472/udp` (Flannel VXLAN), `:8180` (Pi-hole FTL). Localhost-only: `:5380`+`:5353` (Technitium), `:9120` (Komodo), `:8053` (ddns-updater), `:2019` (Caddy admin), `:61209` (glances). **`:50011`, `:19532` and `:19531` are NOT listening** — the `Heimdall/hyperion/` flashing stack is tracked in git but has never been brought up on this host.

**Tracked-but-not-deployed on Heimdall (verified 2026-09-05):** `Heimdall/authentik/`, `Heimdall/cloudflared/`, `Heimdall/hyperion/`. `Heimdall/scripts/deploy.sh` still brings Authentik up unconditionally — reconcile before running it blind.

**k3s control-plane caveat (important):** the control plane runs in a *bridge-networked* Docker container on Heimdall, so its flannel VTEP (`172.19.0.2`) is unreachable from the Pi workers. Consequences (until it's relocated off Heimdall — the planned next step): the control-plane node is tainted `node.homelab/control-plane-only:NoExecute` (**all k8s app workloads must `nodeSelector topology.kubernetes.io/zone=hyperion`**); `kubectl top`/metrics-server is broken; the metallb controller is pinned onto the control-plane node for webhook reachability. Full rationale + the load-bearing `--advertise-address`/`--node-taint` server flags: `docs/design/adr-0002-containerized-control-plane-networking.md` and `Heimdall/k3s-control-plane/README.md`.

GitOps: FluxCD (read-only, no token) reconciles `Hyperion/k8s/`; MetalLB serves the `.10–.99` LoadBalancer pool. See `Hyperion/k8s/README.md`. All 31 Kustomizations use `prune: true` — so anything applied by hand is **not** cleaned up unless Flux has it in its inventory.

**Live objects with no git source (as of 2026-09-05):**
- `kube-system/traefik` — k3s's bundled ingress, holds `.10`, unused. The `--disable=traefik,servicelb` server-flag cleanup is still outstanding.
- `media/orphanarr` — a hand-applied Deployment (`ghcr.io/stevengann/orphanarr:latest`) scaled to **0 replicas**, holding `.89` with no endpoints. Either commit it under `Hyperion/k8s/apps/` or delete it.
- `hermes/alfred-dashboard` — a LoadBalancer on `.11` fronting the Hermes pod's `:8646`. It carries `kustomize.toolkit.fluxcd.io/*` labels but is **not** in `Hyperion/k8s/apps/hermes/service.yaml`, so Flux never prunes it. It also has **no DNS record**, while the Caddyfile does serve an `alfred.lab` site — that route is unreachable by name until a record is added.

**NixOS channel:** still pinned to `nixos-25.11` in `Hyperion/nixos/flake.nix` (deployed generation 5, 2026-06-05, on every node). Its support window has passed; the bump is tracked in `Hyperion/docs/runbooks/nixos-channel-upgrade.md`.

## When you change something

- **`Hyperion/nixos/**`** → CI rebuilds the installer image. Push via Colmena for day-2 changes. See `Hyperion/docs/runbooks/deploy-via-colmena.md`.
- **`Hyperion/nixos/hosts/<hostname>.nix`** → only that host's closure rebuilds. `colmena apply --on <hostname>`.
- **`Hyperion/.sops.yaml`** → re-encrypt all secrets: `sops updatekeys nixos/secrets/common.yaml`.
- **`Hyperion/packer/**`** (Debian, past sunset — do not extend) → CI still rebuilds the relevant Packer image. Same `concurrency: build-images`.
- **`Hyperion/configure-eeprom.sh`** → re-run against affected nodes; not auto-deployed.
- **`Heimdall/k3s-control-plane/`** → not auto-deployed. Re-run `bash Heimdall/scripts/deploy.sh` from the workstation (ships both env secrets + restarts the stack). See `Heimdall/k3s-control-plane/README.md`.
- **`Heimdall/hyperion/`** → same deploy script; see `Heimdall/docs/runbooks/flashing-services.md`. **Note: this stack is not currently running on Heimdall** — bringing it up is a deliberate act, not a restore.
- **k8s manifests under `Hyperion/k8s/`** → reconciled by FluxCD (live since 2026-06-01; read-only, no token). Push to `origin/main` — Flux reads GitHub, not your working tree.

## Pipeline-run records (decision history)

Two completed DEVELOPMENT pipelines and one DEBUGGING pipeline live under `docs/pipeline-runs/` locally (gitignored):

- `20260504T000719Z-dbg-nvme-not-flashing/` — six-hypothesis catalog for the Debian-path reflash failure; conclusion was iterated-on extensively but never closed empirically (per the 00b correction in the later NixOS pipeline).
- `20260517T...-dev-heimdall-*` — Heimdall stack design (Caddy + Technitium + Komodo) and the subsequent migration of Hyperion flashing services to Heimdall.
- `20260523T050133Z-dev-nixos-identity-usb/` — this pivot. FINAL.md is the orienting document; iter-2/04-revision.md is the latest binding text.

The agent-notes Settled-knowledge sections under `docs/agent-notes/*.md` carry the durable Pi/Linux/Hyperion facts that survive each pipeline.
