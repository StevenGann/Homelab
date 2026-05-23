# Homelab IaC

Infrastructure as Code for a home Kubernetes cluster. Every host's state is
defined in this repository and recoverable from scratch.

> **Hyperion is currently mid-pivot** from Debian/Packer to NixOS. The
> Debian path remains active alongside the new NixOS scaffold; both are
> in-tree until the 2026-08-15 sunset gate. See `Hyperion/nixos/README.md`
> and `Hyperion/docs/runbooks/first-node-bringup-nixos.md`.

---

## Repository Structure

```
Homelab/
├── docs/                        # Project-wide documentation
│   ├── todo.md                  # Current task list and next steps
│   ├── design/                  # Architecture planning documents
│   └── pipeline-runs/           # Decision-record outputs (git-ignored, local only)
│
├── Hyperion/                    # Pi 5 k3s worker cluster (10 nodes)
│   ├── nixos/                   # NixOS configuration (Phase 1 scaffold — see README)
│   ├── packer/                  # Debian Packer images (sunsetting 2026-08-15)
│   │   ├── rpi-bootstrap.pkr.hcl
│   │   ├── rpi-node.pkr.hcl
│   │   └── files/
│   ├── ansible/                 # Post-boot config (sunsetting alongside Packer)
│   ├── k8s/                     # Kubernetes manifests (FluxCD GitOps)
│   ├── flash-identity-usb.sh    # Formats per-node identity USB (NixOS schema v2)
│   ├── reimage.sh               # Debian-path: reboots node into Bootstrap SD
│   ├── watch-flash.sh           # Debian-path: live monitor during flashing
│   ├── publish-image.sh         # Debian-path: manual build-and-publish
│   ├── configure-eeprom.sh      # Sets BOOT_ORDER on Pis (KEPT under NixOS too)
│   └── docs/runbooks/           # Hyperion-specific runbooks
│
├── Heimdall/                    # Edge-services + Hyperion flashing host (192.168.10.4)
│   ├── caddy/                   # Reverse proxy / LB / TLS
│   ├── technitium/              # DNS + ad-blocking
│   ├── komodo/                  # Container manager
│   ├── hyperion/                # Flashing services (moved from Monolith 2026-05-21)
│   │   ├── ci-deploy/           # Polls GH Releases, mirrors images
│   │   ├── journal-remote/      # journal-upload sink (:19532) + gatewayd (:19531)
│   │   ├── nginx.conf           # Image server (:50011)
│   │   └── docker-compose.yml
│   └── docs/runbooks/
│
└── Monolith/                    # TrueNAS Scale host (192.168.10.247)
    └── k3s-control-plane/       # k3s server (the flashing/journal stack moved to Heimdall)
        ├── docker-compose.yml
        ├── healthcheck/         # IaC integration test runner (HTTP :50012)
        └── docs/runbooks/
```

Each top-level directory maps to a physical host or cluster. This pattern
extends as IaC coverage expands.

---

## Infrastructure Overview

```
Workstation
  └── Git push → GitHub → CI builds images (Debian Packer + NixOS in parallel during pivot)

Heimdall (192.168.10.4)                          Monolith (192.168.10.247 — TrueNAS Scale)
  ├── caddy (reverse proxy + TLS)                  ├── k3s server (Docker Compose) — Hyperion control plane
  ├── technitium (DNS + adblock)                   └── healthcheck (HTTP :50012)
  ├── komodo (container manager)
  └── hyperion/                                  Hyperion Cluster (k3s)
        ├── nginx :50011 (image server)           ├── Control plane: k3s server on Monolith
        ├── ci-deploy (GH Releases poller)        └── 10 × Pi 5 worker nodes (192.168.10.101–.110)
        ├── journal-remote :19532                      ├── NixOS (Phase 1 — scaffold landed)
        └── journal-gatewayd :19531 (HTML browse)      ├── Identity: HYPERION-ID USB (hostname, age key, SSH host keys)
                                                      └── Workloads: reconciled by FluxCD from this repo
```

### Node imaging flow (NixOS — Phase 1 forward)

```
First install (per node, once per kernel/firmware bump):
  Workstation: nix build .#installerImage
  Workstation: zstd -d <img>.zst | sudo dd of=/dev/sdX (USB-to-NVMe adapter)
  Move NVMe into Pi
  Insert HYPERION-ID identity USB
  Power on
  → Pi 5 EEPROM boots kernel.img from NVMe firmware partition
  → apply-identity.service stages /run/hyperion/identity.env from USB
  → sops-nix decrypts secrets using per-node age key from USB
  → k3s agent registers with Monolith server

Day-2 config changes (no NVMe re-flash):
  Workstation: cd Hyperion/nixos && colmena apply --on hyperion-alpha
  → nix-copy-closure to target → nixos-rebuild switch → done
```

### Node imaging flow (Debian — sunsetting 2026-08-15)

```
Bootstrap SD inserted (hyperion-bootstrap.service):
  Check Heimdall for newer Node IMG → update HYPERION-ID USB cache
  Compare USB cache version vs NVMe version (node-img.ver)
  If NVMe behind → dd NVMe from USB cache → repartition → reboot
  Else → reboot into NVMe immediately

NVMe boot (production Debian):
  apply-identity.service → hostname from HYPERION-ID USB
  detect-node-storage.service → mount best storage device to /mnt/node-storage
```

### Network

All infrastructure is on the Homelab VLAN (`192.168.10.0/24`):

| Range | Purpose |
|-------|---------|
| `.4` | Heimdall (edge services + Hyperion flashing stack) |
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion Pi nodes (alpha → kappa) |
| `.247` | Monolith (TrueNAS + k3s server) |

---

## Provisioning a New Cluster from Scratch

See `docs/todo.md` for the current step-by-step checklist.

**NixOS path (forward, Phase 1+):**

1. **Heimdall** — deploy the hyperion-flashing stack (see `Heimdall/docs/runbooks/flashing-services.md`).
2. **Monolith** — deploy `Monolith/k3s-control-plane/docker-compose.yml` (the k3s server).
3. **Workstation tooling** — install Nix, age, sops, colmena.
4. **EEPROM** — set boot order on each Pi (`./configure-eeprom.sh --reboot`).
5. **NixOS pivot** — follow `Hyperion/nixos/README.md` then `Hyperion/docs/runbooks/first-node-bringup-nixos.md`.
6. **Identity USBs** — flash one per node (`./flash-identity-usb.sh /dev/sdX hyperion-alpha`).
7. **Cluster deploy** — `colmena apply --on '@hyperion-*' --parallel 4`.
8. **FluxCD** — bootstrap GitOps.

**Debian path (legacy, until sunset 2026-08-15):**

See `Hyperion/docs/runbooks/build-packer-image.md` and `debug-flashing.md`. The legacy flow remains available for fallback while Phase 1 NixOS validation is in progress.

---

## Re-imaging a Node

**NixOS:**
- Day-2 config: `cd Hyperion/nixos && colmena apply --on hyperion-<greek>`
- Full re-image (e.g. after NVMe replacement): see `Hyperion/docs/runbooks/replace-dead-node.md`

**Debian (legacy):**
```bash
# Insert Bootstrap SD card into the node, then:
cd ~/GitHub/Homelab/Hyperion
./reimage.sh hyperion-alpha    # or: ./reimage.sh all
```

CI publishes a new image on every push to `main` touching the relevant paths.

---

## Secrets

SOPS + age. Each Pi has its own per-node age private key on its HYPERION-ID USB; the public halves are listed in `Hyperion/.sops.yaml`'s `creation_rules`.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>
```

See `Hyperion/docs/runbooks/tooling.md` for the SOPS/age/Nix tooling
cheat-sheet.

---

## Reproducibility Checklist

- [ ] Monolith services restored from `docker compose up` alone (unchanged)
- [ ] Heimdall services restored from `docker compose up` alone
- [ ] Dead Hyperion node replaced per `Hyperion/docs/runbooks/replace-dead-node.md` (≤30 min)
- [ ] Every workload running in the cluster is defined in `Hyperion/k8s/`
- [ ] All secrets are SOPS-encrypted or stored outside the repo

---

## Pivot status (2026-05-23)

The NixOS pivot for Hyperion completed pipeline approval (2 iterations,
6 YAE / 0 NAY) on 2026-05-23. Phase 1 hard-gate validation on
hyperion-alpha is the next step before scaling to the other 9 nodes.

See:
- `Hyperion/nixos/README.md` — scaffold layout
- `Hyperion/docs/runbooks/first-node-bringup-nixos.md` — Phase 1 walkthrough
- `Hyperion/docs/runbooks/replace-dead-node.md` — hardware-swap procedure
- `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/FINAL.md` — full design rationale (local-only per .gitignore)

The Debian/Packer path sunsets on 2026-08-15 conditional on Phase 1+2
hard-gate criteria. Until then, both stacks are tracked.
