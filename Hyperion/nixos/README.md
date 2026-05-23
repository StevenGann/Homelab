# Hyperion/nixos/

NixOS configuration for the 10-node Pi 5 k3s worker cluster.

**Status:** Phase 1 scaffold — not yet validated on hardware. See
`docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/FINAL.md`
(local-only per `.gitignore`) for the full design rationale and the
phased rollout plan.

## Layout

```
Hyperion/nixos/
├── flake.nix                  ← inputs, nixosConfigurations, colmena hive, installerImage
├── modules/
│   ├── hyperion-base.nix      ← common (users, ssh, packages, networking)
│   ├── hyperion-identity.nix  ← /var/lib/hyperion-id mount, schema check, apply-identity, sops-nix
│   ├── hyperion-pi5.nix       ← hardware.raspberry-pi.config (config.txt directives)
│   ├── hyperion-journal.nix   ← journal-upload → Heimdall :19532
│   └── hyperion-k3s.nix       ← services.k3s agent → Monolith :6443
├── hosts/
│   └── hyperion-{alpha..kappa}.nix  ← per-host nodeLabel / nodeTaint
├── disko/
│   └── nvme-layout.nix        ← declarative NVMe partitioning
├── installer/
│   └── installer.nix          ← the SD/NVMe installer image config
├── identity-overrides/
│   └── hyperion-{alpha..kappa}.env  ← per-node runtime identity (hostname, IP)
└── secrets/
    └── common.yaml            ← sops-encrypted; absent in scaffold until Phase 1 generates the 10 age keys
```

## What you build

```bash
# The installer image (flashed to a blank NVMe once per kernel bump)
nix build .#installerImage

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
   1.34.5; Monolith runs 1.35.3. Within N-1 supported window per
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
