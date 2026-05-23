# Tooling reference — Nix / Colmena / sops-nix / age

Quick reference for the operator-facing tooling delta introduced by the
NixOS pivot. The pipeline's iter-2 honesty pass listed this as the +5
tooling delta the Old Man's anti-complexity discipline flagged:

1. Nix CLI
2. Colmena
3. sops-nix (NixOS module)
4. `nvmd/nixos-raspberrypi` flake
5. Two Cachix substituters (`cache.nixos.org`, `nixos-raspberrypi.cachix.org`)

Each is documented + pinned. None should appear in a runbook without a
line linking to this file.

## Nix CLI

Install: <https://nixos.org/download> or <https://determinate.systems/posts/determinate-nix-installer>.

Most-used commands for this repo:

```bash
nix build .#installerImage              # produces result/sd-image/*.img
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel
nix flake update                        # bumps all inputs
nix flake update --input nixpkgs        # bumps one input
nix flake show                          # lists outputs
nix run nixpkgs#colmena -- ...          # one-off colmena without installing
nix shell nixpkgs#age nixpkgs#sops      # ad-hoc shells with tooling available
```

`flake.lock` is the version-pinning truth. Commit it whenever you bump
an input.

## Colmena

Repo: <https://github.com/zhaofengli/colmena>
Docs: <https://colmena.cli.rs>

Status note: last formal release v0.4.0 (2023-05-15). 2025-11 commits
keep the repo alive. Pinned by commit hash in `flake.nix`, not by tag.

Day-to-day:

```bash
cd Hyperion/nixos
colmena apply --on hyperion-alpha
colmena apply --on '@hyperion-*' --parallel 4
colmena apply --on hyperion-alpha build       # build-only, no activate
colmena nodes                                 # list nodes in the hive
colmena upload-keys --on hyperion-alpha       # push sops-nix secrets
```

See `deploy-via-colmena.md` for the full workflow.

## sops-nix

Repo: <https://github.com/Mic92/sops-nix>

Integrates SOPS-encrypted secrets with NixOS activation. Key insight:
secrets decrypt at activation time using `sops.age.keyFile` (the
per-node age private key on the HYPERION-ID USB).

```bash
# Edit (opens $EDITOR with decrypted contents)
sops nixos/secrets/common.yaml

# Re-encrypt against current key set in .sops.yaml
sops updatekeys nixos/secrets/common.yaml

# Decrypt to stdout (for inspection or scripting)
sops --decrypt nixos/secrets/common.yaml
```

The per-node age private key lives ONLY on each node's HYPERION-ID USB.
The public halves are listed in `Hyperion/.sops.yaml`'s `creation_rules`.

## age

Repo: <https://github.com/FiloSottile/age>

The cryptographic foundation under sops-nix. Used by
`flash-identity-usb.sh` to mint per-node keypairs:

```bash
age-keygen -o /path/to/age-key.txt
# Prints "Public key: age1..." to stderr
```

## `nvmd/nixos-raspberrypi` flake

Repo: <https://github.com/nvmd/nixos-raspberrypi>
Cachix: <https://nixos-raspberrypi.cachix.org>
Pinned tag: `v1.20260517.0`

Provides:
- Pi 5 kernel (BCM2712) with vendor patches needed for NVMe + PCIe Gen 3 + PoE+ HAT
- `boot.loader.raspberry-pi.bootloader = "kernelboot"` (default) and `"uboot"`
- `hardware.raspberry-pi.config` API for emitting `config.txt` directives (see `modules/hyperion-pi5.nix` for the directives we set)

Predecessor `nix-community/raspberry-pi-nix` is archived (2025-03-23)
with Pi 5 USB/NVMe boot explicitly listed under "What's not working" —
do not use it.

If `nvmd/nixos-raspberrypi` ever goes unmaintained, contingency options
in priority order:

1. Pin to the last working tag indefinitely; only bump the kernel via `services.k3s.package`-style override.
2. Fork the flake and maintain a minimal copy under `Hyperion/nixos/flakes/nixos-raspberrypi-mirror/`.
3. Switch to mainline kernel (loses Pi 5 vendor-patch coverage; would need significant validation).

## Cachix substituters

Two substituters configured for this repo's builds:

- `cache.nixos.org` (key: `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`) — official, covers nixpkgs.
- `nixos-raspberrypi.cachix.org` (key: `nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=`) — community, covers the rpi5 kernel.

Configured in:
- `.github/workflows/build-nixos-image.yml` (CI runner)
- The workstation's `~/.config/nix/nix.conf` (operator-side)

Outage path: if either substituter is down, builds fall back to local
compilation. cache.nixos.org is rarely down; nixos-raspberrypi.cachix.org
has had multi-hour outages historically. The kernel rebuild on
`ubuntu-24.04-arm` is ~25 minutes, so this is annoying but not blocking.

## Quick troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `error: cached failure of attribute '...'` | Stale eval cache | `rm -rf ~/.cache/nix/eval-cache-v5` and retry |
| `nix-copy-closure: connection refused` | Target SSH down or wrong IP | `ssh owner@<ip>` first; fix DHCP if needed |
| `sops: file not found` after `sops updatekeys` | YAML structure broken by re-encryption | `sops --decrypt` to inspect; restore from git if needed |
| Build hangs on kernel rebuild | Cachix miss | Check `https://nixos-raspberrypi.cachix.org` reachability; bump the flake input if the kernel was evicted |
| `apply-identity.service failed` on a node | USB mount failed or schema mismatch | SSH in (still works); check `systemctl status apply-identity`; verify USB schema-version file |
