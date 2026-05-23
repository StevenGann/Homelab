# Homelab IaC — To Do

## Status (2026-05-23)

**Hyperion is mid-pivot to NixOS.** The dev-nixos-identity-usb pipeline
(approved 6 YAE / 0 NAY across 2 iterations) lands a full NixOS scaffold
under `Hyperion/nixos/`. **The pivot is not yet hardware-validated —
that is the Phase 1 hard gate.**

The user's mid-pipeline correction (`00b-user-correction.md` in the run
folder): despite many attempts, the existing Debian-path reflash
mechanism does not produce a working node end-to-end. The pivot's job
is to sidestep the broken mechanism with something more IaC-native,
not to iterate on it further.

**Current focus: execute Phase 1 of the NixOS pivot on `hyperion-alpha`.**

Phase-1 walkthrough: [`Hyperion/docs/runbooks/first-node-bringup-nixos.md`](../Hyperion/docs/runbooks/first-node-bringup-nixos.md).

---

## NixOS Pivot — Phase 1 (active)

Triple-redundant exit signals; any halts and triggers iter-3 with
Counter-B promoted:

1. **Hard gate:** NVMe boot fails twice on alpha.
2. **Muddy-failure:** >6 hrs cumulative unplanned operator-intervention
   time in any rolling 7-day window during the phase. Log in
   `intervention-log.md`.
3. **Behavioral:** <3 committed git changes addressing real Phase 1
   work in 5 days. (Largely retired-as-rhetorical-purpose per the user's
   00b correction; kept as sanity check.)

### Step 1 — Workstation tooling (one-time)

```bash
# Install Nix
curl -L https://install.determinate.systems/nix | sh -s -- install

# Install age + sops + colmena via nix
nix profile install nixpkgs#age nixpkgs#sops nixpkgs#colmena
```

### Step 2 — Fill in placeholders in the flake

Three Phase-1 prerequisites in `Hyperion/nixos/`:

- [ ] Replace placeholder SSH pubkey in `modules/hyperion-base.nix`.
- [ ] Pin `inputs.colmena.url` in `flake.nix` to a specific 2025-11 commit hash. Run `nix flake lock --update-input colmena`.
- [ ] Decide k3s skew: accept 1.34.5 worker vs 1.35.3 server (within N-1 window) or override `services.k3s.package`.

### Step 3 — Flash alpha's identity USB

- [ ] Run `./flash-identity-usb.sh /dev/sdX hyperion-alpha`.
- [ ] Note the printed age public key.
- [ ] Add to `Hyperion/.sops.yaml` `creation_rules` under a new entry for `nixos/secrets/*.yaml`.

### Step 4 — Mint and encrypt the first secret

- [ ] Create `Hyperion/nixos/secrets/common.yaml` with the k3s join token (read from `/var/lib/rancher/k3s/server/node-token` on Monolith).
- [ ] Encrypt to the operator key + alpha's age pubkey.

### Step 5 — Build the installer image (CI or local)

- [ ] Commit Phase-1 prep changes + push (CI fires the `Build Hyperion NixOS image` workflow on `ubuntu-24.04-arm` native).
- [ ] Download the published `.img.zst` artifact.

### Step 6 — Flash NVMe on workstation, install in alpha

- [ ] `zstd -d <img>.zst | sudo dd of=/dev/sdX` (USB-to-NVMe adapter).
- [ ] Move NVMe into alpha's M.2 HAT.
- [ ] Insert HYPERION-ID identity USB.
- [ ] Power on.

### Step 7 — Validate the gate criteria

- [ ] SSH `owner@192.168.10.101` succeeds (key auth).
- [ ] `hostnamectl` reports `hyperion-alpha`.
- [ ] `apply-identity.service` active (exited).
- [ ] `kubectl get nodes` on Monolith shows alpha Ready.
- [ ] journal-upload reaches Heimdall `:19531/browse` shows alpha.
- [ ] Warm reboot survives (the rpi-eeprom #718 discriminator).

### Step 8 — Soak

- [ ] 24-hour soak on alpha. Track intervention-log.md.
- [ ] Decision point: continue to Phase 2 (beta) or halt per exit criteria.

---

## NixOS Pivot — Phase 2 (after alpha gate passes)

- [ ] Repeat the Step 3-7 procedure for `hyperion-beta` (a 4 GB Pi — memory-constraint surface).
- [ ] 2-hour soak.
- [ ] Decision: continue to Phase 3 (the other 8 nodes) or halt.

## NixOS Pivot — Phase 3 (rollout)

- [ ] `colmena apply --on hyperion-delta,hyperion-epsilon,hyperion-zeta,hyperion-eta --parallel 4` (batch 1).
- [ ] 30-min soak.
- [ ] `colmena apply --on hyperion-gamma,hyperion-theta,hyperion-iota,hyperion-kappa --parallel 4` (batch 2).
- [ ] All 10 nodes registered with k3s server.

## NixOS Pivot — Phase 4 (day-2 rehearsal)

- [ ] Make a trivial config change, push via Colmena, verify rollout.
- [ ] Test rollback via `nixos-rebuild --rollback switch` on one node.
- [ ] Rotate the k3s token via sops-edit + Colmena. Confirm zero-downtime.

## NixOS Pivot — Phase 5 (docs + retire)

- [ ] Move legacy files into `Hyperion/retired/`:
  - `bootstrap.sh`, `rpi-bootstrap.pkr.hcl`, `rpi-node.pkr.hcl`, `reimage.sh`, `watch-flash.sh`, `publish-image.sh`, `ansible/`
- [ ] Mark `Hyperion/docs/runbooks/{build-packer-image,debug-flashing}.md` as historical.
- [ ] Update `Heimdall/hyperion/` so its `ci-deploy` only polls for the `nvme-*` tag pattern (the Debian Node IMG path retires once retired).

## NixOS Pivot — Phase 6 (sunset gate)

- **2026-08-15 sunset gate.** GitHub Actions workflow `hyperion-sunset-review.yml` auto-opens an issue on 2026-08-01 with the three pass/fail criteria.
- [ ] On all-green: `git rm -r Hyperion/retired/` in a commit titled `chore(hyperion): retire Debian/Packer artifacts at sunset`.
- [ ] On any-red: extend by 4 weeks (max 2 extensions before mandatory revert).
- [ ] Channel bump 25.11 → 26.05 lands inside this window (25.11 EOL 2026-06-30). See `Hyperion/docs/runbooks/nixos-channel-upgrade.md`.

---

## Scheduled — re-evaluate Heimdall as flashing-services home

**By 2027-05-21** (12 months after the Monolith→Heimdall migration), OR
**when the Monolith-replacement host is in production** (whichever first),
run a follow-up pipeline to decide:

- (a) re-migrate the Hyperion flashing services to the new host, OR
- (b) formally adopt Heimdall as the permanent home and update CLAUDE.md / README / network-layout accordingly.

Source: `dev-hyperion-flashing-to-heimdall` FINAL.md Tier 4.3. The
temporary-posture commitment is what made the migration palatable; this
entry exists so the trigger doesn't silently slip into permanence. If
by 2026-11-21 (6-month mark) there is no Monolith-replacement progress,
surface the question early rather than waiting the full 12 months.

---

## Legacy Debian path (sunsetting — kept until 2026-08-15)

The Debian/Packer path remains in-tree as the fallback if the NixOS
pivot's Phase 1+2 gates fail. **All Debian-path TODO items are paused
pending Phase 1 outcome.** If Phase 1 fails, the iter-3 pipeline opens
with Counter-B promoted (delete the reflash loop, keep Debian, gate
reflashes behind an operator-touched `force-reflash` sentinel) — see
the pipeline run's iter-1 Old Man proposal.

The pre-pivot debug pipeline FINAL.md is at
`docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/FINAL.md`.

### Tools that remain useful regardless of pivot outcome

- `Hyperion/configure-eeprom.sh` — EEPROM is below the OS; this script is KEEP under both paths.
- `Hyperion/watch-flash.sh` — live monitor during Debian flashing attempts; gets retired if Phase 1+2 pass.
- `Heimdall/hyperion/` flashing services — serve both Debian and NixOS images via the same nginx.

---

## k3s + FluxCD bring-up (orthogonal to the pivot)

- [ ] Bring k3s agents online on the worker nodes (NixOS handles this via `services.k3s.enable = true`; pivot does this automatically once nodes are imaged).
- [ ] Bootstrap FluxCD against `Hyperion/k8s/`.
- [ ] Migrate existing workloads into `Hyperion/k8s/apps/`.

These are pre-existing TODOs and survive the pivot unchanged.

---

## Node storage layout (NixOS)

| Partition | Size | FS | Mount | Purpose |
|-----------|------|----|-------|---------|
| `nvme0n1p1` | 512 MB | FAT32 | `/boot/firmware` | Pi 5 boot firmware (`kernel.img`, `config.txt`) |
| `nvme0n1p2` | 32 GB | ext4 | `/` | Root OS (NixOS generations live here) |
| `nvme0n1p3` | ~220 GB | ext4 | `/mnt/node-storage` | Node-local ephemeral storage |

Declarative source of truth: `Hyperion/nixos/disko/nvme-layout.nix`.
