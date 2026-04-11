# Runbook: Configure Pi 5 EEPROM Boot Order

One-time step per node. Sets the boot order so each Pi 5 tries SD card first
(Bootstrap IMG), then falls back to NVMe (production OS), then loops.

This is safe to run while nodes are running from NVMe — EEPROM lives in SPI flash
and is unaffected by re-imaging.

---

## Target boot order

`BOOT_ORDER=0xf641` — nibbles read right-to-left:

| Nibble | Mode | Meaning |
|--------|------|---------|
| `1` | 1st | SD card (Bootstrap IMG on SD; skipped when absent) |
| `4` | 2nd | USB mass storage (Bootstrap IMG on USB stick; skipped when absent) |
| `6` | 3rd | NVMe (production OS) |
| `f` | 4th | Loop (restart from beginning) |

**Normal operation (no SD/USB bootstrap media inserted):** Pi skips SD and USB
(no bootable media), boots NVMe directly. Bootstrap IMG only takes effect when
an SD card or USB stick containing it is physically inserted.

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
BOOT_ORDER=0xf641
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
# Expected: BOOT_ORDER=0xf641
```

---

## Re-imaging a node

No EEPROM changes needed for re-imaging. Simply:

1. Insert the Bootstrap SD card **or** USB stick
2. Run `./reimage.sh hyperion-<name>` to reboot the node

The Pi tries SD first, then USB (BOOT_ORDER=0xf641), so Bootstrap takes over
whichever media is present. Remove the bootstrap media after the node reboots
into NVMe.
