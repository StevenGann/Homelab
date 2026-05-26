# Runbook — Remotely flash a Hyperion node (nixos-anywhere)

Install NixOS onto a node's NVMe over the network, with the only hands-on
work being hardware assembly and assigning the node an IP.

This replaces the old "dd image to NVMe on the workstation via a USB-to-NVMe
adapter, then move the NVMe into the Pi, then insert a HYPERION-ID USB" flow.

## Model in one paragraph

A node boots a **live NixOS installer from a resident microSD card** (built
by CI, identical across all 10 nodes). With EEPROM `BOOT_ORDER=0xf16` a blank
NVMe falls through to that SD installer; once the NVMe holds a real install it
wins and the SD is ignored. From the workstation, `flash-node.sh` runs
**nixos-anywhere** against the booted installer: it partitions the NVMe
(disko), builds the per-host closure **on the node** (`--build-on-remote`,
substituted from Cachix), injects the per-node age key + SSH host keys
(`--extra-files`), and reboots. kexec is **not** used — it is broken on the
Pi (see the ADR), so we boot a real installer and skip the kexec phase.

## Why not kexec / nixos-anywhere's default path

nixos-anywhere normally kexecs a non-NixOS host into a RAM installer. That
fails on Raspberry Pi (`nixos-anywhere` #183 "missing /proc/kcore";
`nixos-raspberrypi` has no kexec support). So a node sitting at its old
Raspbian-on-NVMe install **cannot** be the install driver. We boot the SD
installer instead and pass `--phases disko,install,reboot`.

---

## One-time prerequisites (per node, hands-on at assembly)

1. **Flash the SD installer** (once; the image is identical for all nodes):
   ```bash
   # Get the latest from Heimdall (CI publishes it on push to main):
   curl -OL https://192.168.10.4:50011/sd-installer/hyperion-sd-installer-<ver>.img.zst
   zstd -d hyperion-sd-installer-<ver>.img.zst \
     | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   sync
   # (or build locally: cd Hyperion/nixos && nix build .#installerSdImage)
   ```
   Insert the SD into the Pi.

2. **Set EEPROM boot order** to NVMe-first, SD-fallback:
   ```bash
   cd Hyperion
   ./configure-eeprom.sh hyperion-<name> --boot-order 0xf16 --reboot
   ```
   > Existing nodes run Raspbian on the NVMe. The one-time touch is: insert
   > the SD and set `0xf16`. After the first flash, the NVMe (now NixOS) wins.

3. **Assign the IP**: add a UCG DHCP reservation in `.101..110` for the node's
   MAC (alpha=.101 … kappa=.110).

## Workstation prerequisites (once)

- `nix` (with flakes) — to run nixos-anywhere. `age`, `sops`, `ssh-keygen`,
  `tar`, `python3`.
- Operator age key at `~/.config/sops/age/keys.txt` (override with
  `SOPS_AGE_KEY_FILE`).

---

## Flash a node

### 1. Register the node's keys (once per node)

```bash
cd Hyperion
./register-node-key.sh hyperion-<name>
```
This generates a per-node age key + SSH host key, writes the encrypted bundle
`nixos/node-keys/hyperion-<name>.tar.age` (safe to commit — encrypted to the
operator only), adds the age pubkey to `.sops.yaml`, and re-encrypts
`nixos/secrets/common.yaml` so the node can decrypt the k3s token.

Commit the result:
```bash
git add .sops.yaml nixos/secrets/ nixos/node-keys/hyperion-<name>.tar.age
git commit -m "feat(hyperion): register hyperion-<name> key + re-encrypt secrets"
```

### 2. Boot the node into the SD installer

Power on with a blank NVMe (or one you intend to wipe). It boots the SD
installer and gets its reserved IP. Confirm reachability:
```bash
ssh root@192.168.10.<n> true && echo reachable
```

### 3. Install

```bash
cd Hyperion
./flash-node.sh 192.168.10.<n> hyperion-<name>
```
It decrypts the key bundle, confirms (type the hostname), then runs
nixos-anywhere. First run is slowest (the node substitutes the closure);
subsequent nodes are faster (shared Cachix hits). The node reboots into NixOS
on the NVMe automatically.

### 4. Verify

```bash
ssh owner@192.168.10.<n> 'hostnamectl; systemctl is-active k3s'
kubectl get nodes      # hyperion-<name> should reach Ready
```

---

## Day-2 changes (no re-flash)

```bash
cd Hyperion/nixos
colmena apply --on hyperion-<name>
```
See [deploy-via-colmena.md](./deploy-via-colmena.md).

## Re-flash an existing node

The SD installer stays resident. To wipe and reinstall, boot the SD installer
(temporarily set `--boot-order 0xf16` already covers blank disks; for a full
node with a working NVMe, set EEPROM to SD-first or pull the NVMe contents)
and re-run `./flash-node.sh`. The age + host keys are re-injected from the
committed bundle, so SSH known_hosts and sops decryption are unchanged. To
rotate keys: `./register-node-key.sh hyperion-<name> --rotate` then re-flash.

## Rotate / replace a node

- Replace dead node: [replace-dead-node.md](./replace-dead-node.md).
- The encrypted bundle in `nixos/node-keys/` is the durable key source; losing
  it means `--rotate` + re-register + re-flash.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `flash-node.sh: No key bundle` | `register-node-key.sh` not run/committed | Run it, commit, retry |
| nixos-anywhere can't SSH | node booted NVMe not SD, or wrong IP | Confirm `0xf16` + blank NVMe; `ssh root@<ip>` |
| Decrypt fails | wrong operator age key | Check `SOPS_AGE_KEY_FILE` |
| k3s not Ready after boot | token decrypt failed | `journalctl -u sops-install-secrets -u k3s` on the node |
| Slow install (compiling kernel) | Cachix substituter missing | installer sets it; check node has internet to `nixos-raspberrypi.cachix.org` |
