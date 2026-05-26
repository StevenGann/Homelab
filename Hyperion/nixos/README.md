# Hyperion/nixos/

NixOS configuration for the 10-node Pi 5 k3s worker cluster.

**Status:** Phase 1 scaffold — not yet validated on hardware. See
`docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/FINAL.md`
(local-only per `.gitignore`) for the full design rationale and the
phased rollout plan.

## Layout

```
Hyperion/nixos/
├── flake.nix                  ← inputs, nixosConfigurations, colmena hive, installerSdImage
├── modules/
│   ├── hyperion-base.nix      ← common (users, ssh, packages, networking)
│   ├── hyperion-identity.nix  ← sops-nix config (age key at /var/lib/sops-nix/key.txt)
│   ├── hyperion-pi5.nix       ← hardware.raspberry-pi.config (config.txt directives)
│   ├── hyperion-journal.nix   ← journal-upload → Heimdall :19532
│   └── hyperion-k3s.nix       ← services.k3s agent → Heimdall :6443
├── hosts/
│   └── hyperion-{alpha..kappa}.nix  ← per-host hostname, nodeLabel / nodeTaint
├── disko/
│   └── nvme-layout.nix        ← declarative NVMe partitioning (used by the install)
├── installer/
│   └── installer.nix          ← the live SD installer (boots, sshd, waits for nixos-anywhere)
├── node-keys/
│   └── hyperion-<host>.tar.age ← per-node age + SSH host keys, encrypted to the operator
└── secrets/
    └── common.yaml            ← sops-encrypted (k3s token); re-encrypted as nodes register
```

## What you build

```bash
# The installer image (flashed to a blank NVMe once per kernel bump)
nix build .#installerSdImage

# A specific node's complete system closure (built locally for inspection)
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel
```

## What you deploy

```bash
# Day-2 deploy from operator workstation
colmena apply --on hyperion-alpha
colmena apply --on '@hyperion-*' --parallel 4
```

## Phase 1 prerequisites

Before the first `nix build`:

1. Replace the placeholder SSH pubkey in `modules/hyperion-base.nix` with
   the operator's actual public key.
2. Decide Colmena pin: edit `inputs.colmena.url` in `flake.nix` to a
   specific commit hash known to build clean against nixpkgs 25.11.
3. Generate the 10 per-node age keypairs and add their public halves to
   `Hyperion/.sops.yaml`'s `creation_rules`. Encrypt secrets to all 10
   keys + the operator's key. Place encrypted `common.yaml` in
   `secrets/`.
4. Confirm k3s worker-server skew acceptable: nixpkgs 25.11 ships k3s
   1.34.5; Akasha runs 1.35.3. Within N-1 supported window per
   pipeline FINAL.md §C-13. If you need to override, set
   `services.k3s.package` in `modules/hyperion-k3s.nix`.

## Runbooks

See `Hyperion/docs/runbooks/`:

- `first-node-bringup-nixos.md` — Phase 1 walkthrough on hyperion-alpha
- `replace-dead-node.md` — hardware swap procedure
- `deploy-via-colmena.md` — day-2 changes
- `rollback-a-node.md` — generation rollback (with installer-SD recovery details)
- `nixos-channel-upgrade.md` — 25.11 → 26.05 etc.
- `k3s-cve-response.md` — patching k3s outside the nixpkgs cadence
- `tooling.md` — Nix / Colmena / sops-nix / nixos-anywhere quick reference
