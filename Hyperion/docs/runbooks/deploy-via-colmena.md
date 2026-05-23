# Day-2 deploys via Colmena

After a Pi has been brought up via `first-node-bringup-nixos.md`, all
subsequent configuration changes happen via Colmena push from the
operator workstation — no NVMe re-flash, no Ansible playbook re-run.

## Basic flow

```bash
# Edit a module (e.g. Hyperion/nixos/modules/hyperion-base.nix)
$EDITOR Hyperion/nixos/modules/hyperion-base.nix

# Build locally to confirm it evaluates
cd Hyperion/nixos
nix build .#nixosConfigurations.hyperion-alpha.config.system.build.toplevel

# Push to one node
colmena apply --on hyperion-alpha

# Push to a batch
colmena apply --on '@hyperion-*' --parallel 4

# Dry-run (build but don't activate)
colmena apply --on hyperion-alpha build
```

## What Colmena does

1. Evaluates `flake.nix` locally on the workstation
2. Substitutes from `cache.nixos.org` + `nixos-raspberrypi.cachix.org`
3. Builds anything not cached locally
4. `nix-copy-closure` the closure to each target via SSH
5. Activates with `nixos-rebuild switch` on the target
6. If activation fails, the node stays on the previous generation; the
   GRUB/u-boot menu would normally offer rollback — see `rollback-a-node.md` for the Pi 5 reality

## Per-host vs. base changes

- **Change to `modules/`** (base) → affects all 10 nodes when you
  `colmena apply --on '@hyperion-*'`
- **Change to `hosts/<hostname>.nix`** (per-host) → only that node needs
  re-deploy. Colmena evaluates per-host and only rebuilds the affected
  closures.

## Rolling deploys (avoid full-cluster outages)

For changes that risk breaking things (kernel bumps, k3s config changes,
new modules), deploy to a canary first:

```bash
# Step 1: alpha canary
colmena apply --on hyperion-alpha
# Wait 10 minutes; confirm alpha is still Ready and joining workloads
ssh truenas_admin@192.168.10.247 'sudo k3s kubectl get nodes'

# Step 2: 4 GB nodes (beta + gamma) — memory-constraint surface
colmena apply --on hyperion-beta,hyperion-gamma --parallel 2

# Step 3: rest of cluster, in two batches of 4
colmena apply --on hyperion-delta,hyperion-epsilon,hyperion-zeta,hyperion-eta --parallel 4
# Wait 5 min between batches
colmena apply --on hyperion-theta,hyperion-iota,hyperion-kappa --parallel 4
```

## Secret rotation

Secrets in `Hyperion/nixos/secrets/common.yaml` are sops-encrypted to
all 10 per-node age public keys + the operator's key.

```bash
# Edit (sops opens $EDITOR with decrypted contents)
cd Hyperion
sops nixos/secrets/common.yaml

# Re-deploy. sops-nix decrypts at activation; k3s restarts to pick up
# the new token.
cd nixos && colmena apply --on '@hyperion-*' --parallel 4
```

Watch for: a token rotation requires the Monolith k3s server to also
accept the new token. The simplest approach is to read the current
server-side token and put it in sops, rather than minting a new one:

```bash
ssh truenas_admin@192.168.10.247 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

## When NOT to use Colmena

- **NVMe re-flash or first install** — use `dd` per `replace-dead-node.md`.
- **Identity USB regeneration** — use `flash-identity-usb.sh`.
- **Pre-Phase-1 cluster (alpha not yet up on NixOS)** — Colmena needs at
  least one running NixOS target; before that, you're in `dd`-and-boot territory.

## Failure modes

- **`error: file '...' does not exist`** during evaluation: usually a
  module references a runtime-only path (e.g. `/var/lib/hyperion-id/...`)
  via `lib.fileContents`. Don't do that — runtime paths shouldn't appear
  at evaluation time. Use `services.<x>.environmentFile` or a systemd
  activation script instead.
- **Cachix hash mismatch**: upstream `nixos-raspberrypi.cachix.org`
  evicted an older kernel that your flake still pins. Bump
  `inputs.nixos-raspberrypi.url` to a newer tag, run
  `nix flake lock --update-input nixos-raspberrypi`, retry.
- **`nix-copy-closure: target not reachable`**: check the node's DHCP
  reservation, check SSH key auth (`ssh owner@<ip>` should work).
- **k3s post-switch hangs**: see `rollback-a-node.md`.
