# Runbook: Populate TFTP Root with Pi 5 Boot Files

The TFTP root must contain the Pi 5 boot firmware files so nodes can netboot.
These files are extracted directly from the same Raspberry Pi OS image that
Packer uses, ensuring the TFTP environment matches the OS being deployed.

## Prerequisites

- ~600MB free disk space on your workstation for the image download
- SSH access to Monolith (`ssh sydney@192.168.10.247`)
- The TFTP directory exists: `/mnt/App-Storage/Container-Data/k3s-control-plane/tftp/`

## Steps

### 1. Download the Pi OS image (if not already present)

```bash
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz
xz -d 2025-12-04-raspios-trixie-arm64-lite.img.xz
```

### 2. Find the boot partition offset

```bash
fdisk -l 2025-12-04-raspios-trixie-arm64-lite.img
```

Look for the FAT32 partition (type `W95 FAT32 (LBA)` or `c`). Note the **Start** sector value.

Example output:
```
Device                                      Boot  Start     End Sectors  Size Id Type
2025-12-04-raspios-trixie-arm64-lite.img1          8192  1056767 1048576  512M  c W95 FAT32 (LBA)
2025-12-04-raspios-trixie-arm64-lite.img2       1056768 ...
```

The Start sector for the boot partition is `8192` in this example.

### 3. Mount the boot partition

Multiply the Start sector by 512 to get the byte offset:

```bash
# Example: 8192 * 512 = 4194304
sudo mount -o loop,offset=$((8192 * 512)) 2025-12-04-raspios-trixie-arm64-lite.img /mnt
```

Replace `8192` with the actual Start sector from your `fdisk` output.

### 4. Copy boot files to Monolith

```bash
scp -r /mnt/* sydney@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/tftp/
```

### 5. Unmount

```bash
sudo umount /mnt
```

### 6. Verify key Pi 5 files are present on Monolith

SSH into Monolith and confirm these files exist in the TFTP root:

```bash
ls /mnt/App-Storage/Container-Data/k3s-control-plane/tftp/
```

Required files:
- `config.txt`
- `kernel_2712.img` (Pi 5 kernel)
- `bcm2712-rpi-5-b.dtb` (Pi 5 device tree)
- `overlays/` directory

> **Note:** `cmdline.txt` will be replaced with a custom version pointing to the
> NFS netboot root. Do not use the stock `cmdline.txt` from this image.

## When to Re-run

Re-run this runbook whenever the Pi OS image version is updated in
`Hyperion/packer/rpi-base.pkr.hcl`. The TFTP files must match the image
being deployed.
