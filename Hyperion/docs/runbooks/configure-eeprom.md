# Runbook: Configure Pi 5 EEPROM Boot Order

One-time step per node. Sets the boot order so each Pi 5 tries SD card first
(Bootstrap IMG), then falls back to NVMe (production OS), then loops.

This is safe to run while nodes are running from NVMe — EEPROM lives in SPI flash
and is unaffected by re-imaging.

---

## Target boot order

`BOOT_ORDER=0xf61` — nibbles read right-to-left:

| Nibble | Mode | Meaning |
|--------|------|---------|
| `1` | 1st | SD card (Bootstrap IMG when inserted; skipped when absent) |
| `6` | 2nd | NVMe (production OS) |
| `f` | 3rd | Loop (restart from beginning) |

**Normal operation (no SD card inserted):** Pi skips SD (no bootable media), boots
NVMe directly. Bootstrap SD only takes effect when physically inserted.

---

## Configure all nodes via script

```bash
cd ~/GitHub/Homelab/Hyperion
./configure-eeprom.sh --reboot
```

Default SSH user is `pi` (fresh Pi OS). For nodes already provisioned with the
Node IMG, use `--user owner`:

```bash
./configure-eeprom.sh --user owner --reboot
```

To configure a single node:
```bash
./configure-eeprom.sh hyperion-alpha --user owner --reboot
```

---

## Configure manually (one node)

SSH into the node:

```bash
ssh owner@192.168.10.10x
```

Edit the EEPROM config:

```bash
sudo rpi-eeprom-config --edit
```

Set:
```
BOOT_ORDER=0xf61
```

Save and reboot:

```bash
sudo reboot
```

---

## Verify

After reboot:

```bash
sudo rpi-eeprom-config | grep BOOT_ORDER
# Expected: BOOT_ORDER=0xf61
```

---

## Re-imaging a node

No EEPROM changes needed for re-imaging. Simply:

1. Insert the Bootstrap SD card
2. Run `./reimage.sh hyperion-<name>` to reboot the node

The Pi will find the SD card (BOOT_ORDER tries SD first) and Bootstrap takes over.
Remove the SD card after the node reboots into NVMe.
