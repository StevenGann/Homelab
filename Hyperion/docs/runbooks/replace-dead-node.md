# Replace a dead Pi (or bring up node N+1)

The hardware-replacement story under the NixOS architecture. Three operator steps preserved from the Debian path, with one additional step for a brand-new (never-imaged) Pi.

## Quick reference

| Scenario | Steps |
|---|---|
| **Pi died, replacement available** | Move identity USB → update UCG DHCP → power on |
| **Brand-new Pi (or NVMe wiped/replaced)** | Above three + flash NVMe via `dd` first |
| **Add an 11th node (cluster growth)** | Generate identity USB → flash NVMe → register age key |

## Scenario 1 — Pi died, identical replacement

The simplest case. Assumes the dead Pi's NVMe still works (e.g. the Pi
itself burned out but the SSD survived) OR there's a replacement Pi with
its NVMe already imaged from a prior pre-flash.

1. Power off the dead Pi.
2. Move the HYPERION-ID identity USB from the dead Pi to the replacement.
3. If the replacement also has its own (different) NVMe pre-flashed, move
   the NVMe to the replacement too (or swap if the dead Pi's NVMe survived).
4. Update the UCG DHCP reservation: change the MAC for that Greek-letter
   IP to the replacement Pi's MAC.
5. Power on the replacement.

That's it. Three operator steps + a DHCP edit. Same as the Debian path.

## Scenario 2 — Brand-new Pi, blank NVMe

A new Pi with a virgin NVMe. The NVMe needs imaging once before the Pi
can boot NixOS.

1. **On the workstation:** flash the latest Hyperion NixOS image to the
   new NVMe via a USB-to-NVMe adapter:

   ```bash
   curl -OL http://192.168.10.4:50011/nvme/hyperion-nvme-latest.img.zst
   zstd -d hyperion-nvme-latest.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   sync
   ```

   (`/dev/sdX` is the USB-to-NVMe adapter — confirm with `lsblk`.)

2. Move the freshly-flashed NVMe into the new Pi's M.2 HAT.

3. Configure the new Pi's EEPROM for NVMe-first boot (one-time per
   physical Pi; survives NVMe swaps):

   ```bash
   ssh-keygen -R 192.168.10.1XX   # remove old fingerprint if reusing the IP
   ./configure-eeprom.sh hyperion-<greek> --reboot
   ```

4. Move the HYPERION-ID identity USB from the dead Pi (or generate a new
   one — see Scenario 3).

5. Update the UCG DHCP reservation for the new Pi's MAC.

6. Power on the new Pi.

Four operator steps + the one-time EEPROM step. The EEPROM step is a
real addition vs. the Debian path's "insert bootstrap medium and power on"
— but only required once per physical Pi, ever.

## Scenario 3 — Add an 11th node (cluster growth)

The cluster currently has 10 nodes (alpha..kappa). To add an 11th:

1. Pick a Greek letter not in use (e.g. lambda).

2. Add the per-host file:

   ```bash
   cp Hyperion/nixos/hosts/hyperion-delta.nix Hyperion/nixos/hosts/hyperion-lambda.nix
   # Edit hostname inside the new file
   ```

3. Add the per-node identity override:

   ```bash
   cat > Hyperion/nixos/identity-overrides/hyperion-lambda.env <<EOF
   HYPERION_HOSTNAME=hyperion-lambda
   HYPERION_NODE_IP=192.168.10.111
   HYPERION_ROLE=worker
   EOF
   ```

4. Add `hyperion-lambda` to the `hostnames` list in `Hyperion/nixos/flake.nix`.

5. Add `hyperion-lambda` to `Hyperion/ansible/inventory.yaml` (still useful for ad-hoc SSH; no Ansible playbooks fire under NixOS).

6. Generate the lambda identity USB (creates the per-node age key):

   ```bash
   cd Hyperion
   ./flash-identity-usb.sh /dev/sdX hyperion-lambda
   ```

7. Add the printed age public key to `Hyperion/.sops.yaml` and
   re-encrypt:

   ```bash
   sops updatekeys nixos/secrets/common.yaml
   ```

8. Commit:

   ```bash
   git add nixos/hosts/hyperion-lambda.nix nixos/identity-overrides/hyperion-lambda.env \
           nixos/flake.nix ansible/inventory.yaml .sops.yaml nixos/secrets/common.yaml
   git commit -m "feat(hyperion): add hyperion-lambda (11th node)"
   ```

9. Continue with Scenario 2 (flash NVMe + EEPROM + power on).

10. After the new node boots and joins the cluster, optionally push the
    latest closure to confirm Colmena targets it correctly:

    ```bash
    cd Hyperion/nixos && colmena apply --on hyperion-lambda
    ```

## Time budget

The plan target is **≤30 minutes** for an 11th-node bring-up. Honest
breakdown:

- Workstation `dd` of installer image: ~3 min (image is ~1 GB compressed,
  ~3 GB uncompressed; NVMe write speed depends on the USB-to-NVMe
  adapter)
- USB physical install: 2 min
- `flash-identity-usb.sh`: ~1 min
- Adding files + sops updatekeys + commit: ~10 min
- UCG DHCP reservation edit (manual via UI): ~3 min
- EEPROM configure + reboot wait: ~5 min
- First boot + join: ~2 min
- Verification: ~4 min

Total: ~30 minutes. If you blow past 30 minutes, something has gone
sideways — log it in `intervention-log.md` and check the muddy-failure
exit budget (`first-node-bringup-nixos.md` Phase 1 gate criteria).
