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
└── Heimdall/                    # Edge-services + Hyperion flashing + k3s control plane (192.168.10.4)
    ├── caddy/                   # Reverse proxy / LB / TLS
    ├── technitium/              # DNS + ad-blocking (composed in root compose)
    ├── komodo-data/             # Container manager state (composed in root compose)
    ├── hyperion/                # Flashing services (moved from Akasha 2026-05-21)
    │   ├── ci-deploy/           # Polls GH Releases, mirrors images
    │   ├── journal-remote/      # journal-upload sink (:19532) + gatewayd (:19531)
    │   ├── nginx.conf           # Image server (:50011)
    │   └── docker-compose.yml
    ├── k3s-control-plane/       # k3s server (moved from Akasha 2026-05-24)
    │   ├── docker-compose.yml   # rancher/k3s:v1.34.5-k3s1
    │   ├── .env.example
    │   └── README.md            # Initial mint + deploy + token rotation
    └── docs/
```

Akasha (`192.168.10.247`) is the TrueNAS Scale host, renamed from Monolith on
2026-05-24 and being renovated to a pure-storage role once Hyperion is
operational. No tracked code under `Akasha/` — the old broken k3s control
plane was deleted along with the rename.

Each top-level directory maps to a physical host or cluster. This pattern
extends as IaC coverage expands.

---

## Infrastructure Overview

```
Workstation
  └── Git push → GitHub → CI builds images (Debian Packer + NixOS in parallel during pivot)

Heimdall (192.168.10.4)                          Hyperion Cluster (k3s)
  ├── caddy (reverse proxy + TLS)                  ├── 10 × Pi 5 worker nodes (192.168.10.101–.110)
  ├── technitium (DNS + adblock)                   │     ├── NixOS (Phase 1 — scaffold landed)
  ├── komodo (container manager)                   │     ├── Identity: HYPERION-ID USB (hostname, age key, SSH host keys)
  ├── hyperion/                                    │     └── Workloads: reconciled by FluxCD from this repo
  │   ├── nginx :50011 (image server)              │
  │   ├── ci-deploy (GH Releases poller)           └── Control plane: rancher/k3s container on Heimdall (:6443)
  │   ├── journal-remote :19532
  │   └── journal-gatewayd :19531 (HTML browse)
  └── k3s-control-plane/
        └── rancher/k3s:v1.34.5-k3s1 (server, :6443)

Akasha (192.168.10.247 — TrueNAS Scale)
  └── renovating to pure storage; no tracked code here
```

### Node imaging flow (NixOS — Phase 1 forward)

```
One-time at assembly (the only hands-on):
  Flash the live SD installer to a microSD, insert it
    (CI build .#installerSdImage, or Heimdall /sd-installer/)
  EEPROM BOOT_ORDER=0xf16 (NVMe → SD installer fallback)
  Assign a UCG DHCP reservation (.101..110)

Remote install (from the workstation — docs/runbooks/remote-flash-a-node.md):
  ./register-node-key.sh hyperion-alpha          # once: gen + register keys, commit
  Power on (blank NVMe) → boots SD installer, SSH-reachable
  ./flash-node.sh <ip> hyperion-alpha
  → nixos-anywhere: disko partitions NVMe, builds the closure on the node
    (--build-on-remote), injects age key + SSH host keys (--extra-files),
    reboots; kexec SKIPPED (broken on Pi). No NVMe handling, no identity USB.
  → k3s agent registers with Heimdall control plane (https://192.168.10.4:6443)

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
| `.4` | Heimdall (edge services + Hyperion flashing stack + k3s control plane) |
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion Pi nodes (alpha → kappa) |
| `.247` | Akasha (TrueNAS Scale; renovating to pure storage) |

---

## Provisioning a New Cluster from Scratch

See `docs/todo.md` for the current step-by-step checklist.

**NixOS path (forward, Phase 1+):**

1. **Heimdall** — deploy the hyperion-flashing stack and the **k3s control plane**: `bash Heimdall/scripts/deploy.sh` (see `Heimdall/docs/runbooks/flashing-services.md` + `Heimdall/k3s-control-plane/README.md`).
2. **Workstation tooling** — install Nix, age, sops, colmena.
3. **EEPROM** — set boot order on each Pi (`./configure-eeprom.sh --reboot`).
4. **NixOS pivot** — follow `Hyperion/nixos/README.md` then `Hyperion/docs/runbooks/first-node-bringup-nixos.md`.
5. **Identity USBs** — flash one per node (`./flash-identity-usb.sh /dev/sdX hyperion-alpha`), then `./register-node-key.sh hyperion-alpha age1...`.
6. **Cluster deploy** — `colmena apply --on '@hyperion-*' --parallel 4`.
7. **FluxCD** — bootstrap GitOps.

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

- [ ] Heimdall services (k3s control plane + flashing stack + edge services) restored from `bash Heimdall/scripts/deploy.sh` alone
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
