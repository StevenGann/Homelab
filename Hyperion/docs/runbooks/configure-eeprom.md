# Runbook: Configure Pi 5 EEPROM Boot Order

One-time step per node. Sets the boot order so each Pi 5 tries NVMe first, falls
back to network boot for provisioning, and falls back further to SD/USB if needed.

Must be done while the node is running its existing OS (before wiping).

---

## Boot Order

`BOOT_ORDER=0xf416` — right to left:

| Digit | Mode | Meaning |
|-------|------|---------|
| `4` | 1st | NVMe (PCIe SSD via M.2 HAT) |
| `1` | 2nd | SD card |
| `6` | 3rd | USB mass storage |
| `f` | 4th | Loop (restart from beginning) |

After imaging, nodes boot from NVMe. If the NVMe has no bootable OS (e.g. during
reprovisioning), the loop continues to network boot — **but network boot is not
in this order**. To trigger network boot, temporarily set `BOOT_ORDER=0xf21`
(network → SD → loop) or hold SHIFT during boot if supported.

> **Reprovisioning approach:** To re-image a node, boot it with `BOOT_ORDER=0xf21`
> (network first), let the imaging script run, then restore `BOOT_ORDER=0xf416`.

---

## Steps

SSH into the node:

```bash
ssh pi@192.168.10.10x  # replace with node's IP
```

Edit the EEPROM config:

```bash
sudo rpi-eeprom-config --edit
```

Add or update the `BOOT_ORDER` line:

```
BOOT_ORDER=0xf416
```

Save and exit (`Ctrl+O`, `Ctrl+X` in nano). The change takes effect on next reboot:

```bash
sudo reboot
```

---

## Do All Nodes via Ansible

Once SSH access is confirmed on all nodes, run from your workstation:

```bash
cd ~/GitHub/Homelab/Hyperion
ansible-playbook ansible/configure-eeprom.yml
```

> **Note:** The `configure-eeprom.yml` playbook is yet to be written. For now,
> do this step manually per node as above.

---

## Verify

After reboot, confirm the EEPROM setting took effect:

```bash
sudo rpi-eeprom-config | grep BOOT_ORDER
```

Expected output:
```
BOOT_ORDER=0xf416
```

---

## Reprovisioning a Node

To re-image a node from scratch:

1. SSH in and temporarily change boot order to network-first:
   ```bash
   sudo rpi-eeprom-config --edit
   # Set: BOOT_ORDER=0xf21
   sudo reboot
   ```
2. Node boots from network → imaging script runs → NVMe is re-flashed
3. Node reboots from NVMe → cloud-init runs → rejoins cluster
4. SSH back in and restore permanent boot order:
   ```bash
   sudo rpi-eeprom-config --edit
   # Set: BOOT_ORDER=0xf416
   sudo reboot
   ```
