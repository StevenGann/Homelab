# Rollback a node to the previous generation

NixOS atomic generations give a clean rollback story on x86/UEFI — pick
a previous generation from the bootloader menu, reboot. **On Pi 5 the
story is different.** This runbook documents what actually works.

## The Pi 5 reality

The flake currently uses `boot.loader.raspberry-pi.bootloader = "kernelboot"` (Pi 5 default).

Under `kernelboot`:
- The active generation's kernel is staged as literal `kernel.img` in
  the FAT firmware partition.
- The Pi 5 EEPROM (BCM2712) reads `kernel.img` from `/boot/firmware/`
  and boots it. **There is no boot-time menu.**
- Generation rollback requires either (a) booting an installer SD card
  to manually re-stage a previous generation's `kernel.img`, or (b)
  switching to `bootloader = "uboot"` mode (which provides an extlinux
  menu over UART/HDMI).

Under `uboot` (not yet used):
- U-Boot exposes an extlinux menu via UART or HDMI.
- Operator can select a prior generation interactively.
- But `uboot` on Pi 5 is less-traveled territory; Phase 1 chose `kernelboot` for the documented happy path.

## What you can rollback from where

### From a running node (worked-then-broke)

If the node is still booted and accessible (e.g. the new generation
activated and started misbehaving but you can still SSH in):

```bash
ssh owner@hyperion-alpha
# List recent generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Switch to the previous generation in-place (no reboot)
sudo nixos-rebuild --rollback switch

# Or from the workstation, re-push the previous commit's closure:
cd Hyperion/nixos
git checkout <previous-commit>  # the commit whose closure you want to restore
colmena apply --on hyperion-alpha
git checkout main
```

This is the **happy path** for rollback — same as a normal Colmena
deploy, just pointing at an older closure.

### From a brick (booted-then-broke-on-next-boot)

If the new generation booted but the node hangs or fails to come back
on reboot, `kernelboot` has already overwritten `kernel.img` with the
new generation. You can't get back to the old one without re-staging.

**Recovery path A — Installer SD card (works always):**

1. Boot the installer SD card (built by `nix build .#installerSdImage`,
   flashed to a spare USB stick or SD).
2. SSH into the installer (DHCP, password `imaging`).
3. Mount the NVMe partitions:
   ```bash
   sudo mount /dev/nvme0n1p2 /mnt          # root
   sudo mount /dev/nvme0n1p1 /mnt/boot/firmware  # firmware
   ```
4. List available generations:
   ```bash
   sudo nix-env --list-generations \
     --profile /mnt/nix/var/nix/profiles/system
   ```
5. Re-stage a previous generation's kernel:
   ```bash
   sudo nixos-enter --root /mnt -- nixos-rebuild --rollback boot
   ```
6. Power off, remove installer SD, power on.

**Recovery path B — Re-flash NVMe from a known-good image:**

If the installer SD doesn't have what we need (rare; the installer is
generation-agnostic) or recovery-path-A fails:

1. Move the NVMe to the workstation via USB-to-NVMe adapter.
2. Flash the last known-good installer image:
   ```bash
   curl -OL http://192.168.10.4:50011/nvme/hyperion-nvme-<last-good>.img.zst
   zstd -d hyperion-nvme-<last-good>.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync
   ```
3. Move NVMe back into the Pi, power on.
4. Colmena push the desired state once the Pi is back.

This is the same workflow as `replace-dead-node.md` Scenario 2; the
"recovery" framing is just operator intent.

## When to switch to `uboot` mode

If you find yourself doing installer-SD recovery more than once per
quarter, consider switching to `uboot`:

```nix
# Hyperion/nixos/modules/hyperion-pi5.nix
boot.loader.raspberry-pi.bootloader = "uboot";  # was "kernelboot"
```

Then:

```bash
cd Hyperion/nixos
colmena apply --on hyperion-alpha
```

The next reboot uses U-Boot. Test that the extlinux menu shows up over
UART (you'll need a USB-to-TTL serial adapter — Adafruit 954 or similar
— wired to the Pi 5's UART pins).

Trade-off: `uboot` adds a stage to the boot chain, slightly slower cold
boots, and one more thing that can go wrong. Phase 1 chose `kernelboot`
specifically to avoid this complexity until it earns its place.

## Tracking rollback events

Every installer-SD recovery is a "muddy-failure" event per the Phase 1+
exit criteria. Log them in `intervention-log.md` with the timestamp,
the cause, and the time spent. If you exceed 6 hours in any rolling
7-day window, the pipeline's muddy-failure gate has fired and Counter-B
(revert to Debian) is on the table.
