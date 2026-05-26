# NixOS channel upgrade (25.11 → 26.05 etc.)

NixOS releases new channels every 6 months (May / November). Channels
are supported for 7 months. The pinned channel in `Hyperion/nixos/flake.nix` is `nixos-25.11` (Xantusia), supported through 2026-06-30.

The next bump is 25.11 → **26.05** (Yarara, release date ~2026-05-31).
This must happen before 2026-06-30 to avoid running an EOL channel.

## When

- **Soft deadline:** the next minor release of `nvmd/nixos-raspberrypi`
  tagged against `nixos-26.05`, usually within 2-4 weeks of the
  channel's release.
- **Hard deadline:** 2026-06-30 (25.11 EOL).
- **Conveniently:** the sunset window for retiring `Hyperion/retired/` is 2026-08-15, so the channel bump must happen *during* the sunset window.

## Procedure

### Step 1 — Update the inputs

```bash
cd Hyperion/nixos
nix flake update --input nixpkgs --input nixos-raspberrypi
git diff flake.lock
```

Verify the lock file shows the expected channel bump (look for `nixos-26.05` in the nixpkgs ref).

### Step 2 — Build locally

```bash
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel
nix build .#installerSdImage
```

Both should succeed. Note the wall-clock — if it's >30 min, the kernel
likely needs a local rebuild because Cachix doesn't yet have the new
channel's rpi5 kernel. Wait a week and retry, or accept the longer build.

### Step 3 — Update the flake.nix channel reference

```bash
$EDITOR Hyperion/nixos/flake.nix
# Change: nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
# To:     nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
```

Run `nix flake update --input nixpkgs` again to make sure the lock
matches the URL.

### Step 4 — Read upstream release notes

Check <https://nixos.org/manual/nixos/stable/release-notes.html#sec-release-26.05>
for breaking changes. Particular attention to:

- `services.k3s` option renames or removals
- `systemd` version bumps that might change unit semantics
- `boot.loader.raspberry-pi.*` API changes
- `sops-nix` activation-order changes

### Step 5 — Canary deploy

```bash
cd Hyperion/nixos
colmena apply --on hyperion-alpha
# Wait 1 hour. Check kubectl get nodes, journal-upload, etc.
```

### Step 6 — Roll the cluster

```bash
# 4 GB nodes first (memory-constraint surface)
colmena apply --on hyperion-beta,hyperion-gamma --parallel 2

# Wait 30 min, then the rest in two batches
colmena apply --on hyperion-delta,hyperion-epsilon,hyperion-zeta,hyperion-eta --parallel 4
colmena apply --on hyperion-theta,hyperion-iota,hyperion-kappa --parallel 4
```

### Step 7 — Commit

```bash
git add flake.nix flake.lock
git commit -m "deps(hyperion): bump nixpkgs channel 25.11 → 26.05"
```

### Step 8 — Rebuild the installer image

Push to main triggers `build-nixos-image.yml`. The new installer image
becomes the canonical first-install artifact for any future hardware
replacement.

## Rollback (if the upgrade breaks something)

`git revert` the channel-bump commit. Push. Colmena apply reverts.
NixOS generations on each node still have the previous closure
available; in the worst case run `nixos-rebuild --rollback switch` on
the misbehaving node via SSH.

## Cadence

Plan for one channel bump every ~6 months. Budget: ~1 day of testing
+ rollout, mostly soak time between batches.
