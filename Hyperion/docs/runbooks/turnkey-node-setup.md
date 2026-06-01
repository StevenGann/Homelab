# Turnkey node setup — RasPi-OS bootstrap → NixOS worker

**This is the current, validated path** (hyperion-alpha, 2026-06-01). It
supersedes the SD-installer + `flash-node.sh` flow in
[`remote-flash-a-node.md`](remote-flash-a-node.md) for the
operator's "one RasPi-OS SD moved node-to-node" model.

One command per node, run from the workstation on the `192.168.10.0/24` VLAN:

```bash
cd Hyperion
./setup-hyperion-node.sh --name hyperion-beta --ip 192.168.10.102
# or, with the IP in inventory.yaml:
./setup-hyperion-node.sh --name hyperion-beta
```

## The only hands-on step

Insert the **single, reused** stock Raspberry-Pi-OS SD (user `pi`, password
`raspberry`, SSH enabled) into the target node and power it on. The NVMe is a
**separate** disk — we install onto it; the SD is throwaway bootstrap. After
the script reboots the node into NixOS, pull the SD and move it to the next
node.

## What the script does (6 phases)

0. **Preflight** — validate name/IP, tools, operator age key, reachability.
1. **Bootstrap access** — install the workstation SSH key + a NOPASSWD sudoers
   drop-in on `pi` (via the default password, once). Refuses if root is already
   on the NVMe (not a bootstrap node).
2. **Register keys** — `register-node-key.sh <name>` (per-node age + SSH host
   keys, `.sops.yaml`, re-encrypt `common.yaml`). Skipped if already registered.
3. **Prepare** — install Determinate Nix on the bootstrap, point it at
   `cache.nixos.org` + `nixos-raspberrypi.cachix.org`, rsync the flake, stage
   the decrypted secret tree.
4. **Flash** — `disko-install` partitions `/dev/nvme0n1`, builds/substitutes the
   `hyperion-<name>` closure, injects the age key + SSH host keys. It then
   **finishes the bootloader via `nixos-enter`** (see gotcha below).
5. **EEPROM + reboot** — set `BOOT_ORDER=0xf416` (NVMe → SD → USB → loop) and
   reboot. NVMe now wins; the SD is ignored.
6. **Verify** — wait for the node to return as NixOS, confirm root-on-NVMe,
   sops-decrypted token, and `k3s` active.

## Two gotchas baked into the script (why the extra steps exist)

- **sops-nix `mount` not on PATH during offline `disko-install`.** Its
  activation aborts *before* the kernelboot install, leaving `/boot/firmware`
  empty (node won't boot). The script finishes with
  `nixos-enter … switch-to-configuration boot` with util-linux on PATH, which
  stages `kernel.img` / `initrd` / `config.txt`.
- **Pi kernel disables the memory cgroup by default.** Without
  `cgroup_enable=memory` k3s dies with `failed to find memory cgroup (v2)`.
  Fixed in `nixos/modules/hyperion-base.nix` `boot.kernelParams` — now baked
  into every closure, so new nodes get it from first boot.

## Prerequisites

- Workstation on the `.10` VLAN with `age`, `sops`, `ssh-keygen`, `rsync`,
  `python3`, `ssh`, and the operator age key at
  `~/.config/sops/age/keys.txt`. **No Nix needed on the workstation** — the
  closure builds/substitutes on the node.
- The **Heimdall k3s control plane must be up** for the node to reach `Ready`:
  `docker compose -f Heimdall/k3s-control-plane/docker-compose.yml up -d`
  (see [`flashing-services.md`](../../../Heimdall/docs/runbooks/flashing-services.md)
  and the k3s-control-plane README). The k3s server token in
  `Heimdall/secrets/k3s-control-plane.sops.env` must equal the worker token in
  `Hyperion/nixos/secrets/common.yaml` (same `openssl rand -hex 32`).

## Confirm the join

```bash
ssh owner@192.168.10.4 'docker exec k3s-control-plane-k3s-server-1 kubectl get nodes -o wide'
```

## Naming & IPs (important)

The UCG assigns each node's IP by **MAC reservation** (`.101`=alpha … `.110`=kappa),
**not by power-on order**. The Hyperion Pis are a mix of hardware batches
(`88:a2:9e:50:xx` and `2c:cf:67:xx`), so the 5th Pi you power on may come up on
`.106`, not `.105`. **Flash each node by the IP it actually comes up on** — the
greek name follows the IP (per `inventory.yaml`), which keeps hostname↔IP aligned
and avoids a name clash when the skipped node powers on later. To discover a
freshly-booted node's IP, sweep the un-done addresses for the one answering SSH
as the bootstrap (`pi@Homelab-Bootstrap`).

## Flashing in parallel

The single-SD model is one node at a time. To flash several at once you need
**one bootstrap SD per node** (clone the card — ideally one already through a
flash so its Nix store is warm → each run is the ~2.5 min "0 paths downloaded"
path). Then, because Phase 2 mutates shared files (`.sops.yaml` + `common.yaml`),
**pre-register serially and fan out with `--no-register`**:

```bash
for g in eta iota kappa; do ./register-node-key.sh hyperion-$g; done
git add .sops.yaml nixos/secrets nixos/node-keys && git commit -m 'register eta..kappa'
./setup-hyperion-node.sh --name hyperion-eta  --yes --no-register &
./setup-hyperion-node.sh --name hyperion-iota --yes --no-register &
wait
```

The register step is also `flock`-guarded and all node SSH uses
`UserKnownHostsFile=/dev/null`, so concurrent runs don't corrupt shared state or
race on `known_hosts` — but `--no-register` after a serial pre-register is the
clean, fully race-free path.

## Cosmetic / non-blocking notes

- **UniFi shows `Homelab-Bootstrap` for nodes.** NixOS's dhcpcd sent no hostname
  by default, so the UCG kept the name learned during the bootstrap phase. Fixed
  in `hyperion-base.nix` (`networking.dhcpcd.extraConfig = "hostname"`); nodes
  flashed after 2026-06-01 advertise `hyperion-<greek>`. Apply to already-flashed
  nodes with a day-2 rebuild (Colmena, or `nixos-rebuild switch` on the node).
- **`warning: unknown setting 'eval-cores' / 'lazy-trees' / 'no-write-lock-file'`**
  during the flash — Determinate-Nix-specific config keys that the `disko-install`
  nix doesn't recognize. Printed and ignored; harmless.
- **The HYPERION-ID USB drives are inert/removable** — no NixOS node mounts or
  depends on them (secrets live on the NVMe at `/var/lib/sops-nix/key.txt`).

## Day-2 changes

Once a node runs NixOS, push config changes with Colmena (no re-flash):
`cd nixos && colmena apply --on hyperion-<name>` — see
[`deploy-via-colmena.md`](deploy-via-colmena.md). (Colmena needs Nix on the
workstation.) **No-Nix alternative** (what we used to apply the cgroup fix):
rsync `nixos/` to the node and run `sudo nixos-rebuild switch --flake
/home/owner/hyperion-nixos#hyperion-<name>` on the node itself.
