# hyperion-pi5.nix — Pi 5 hardware-specific config.txt directives.
#
# nvmd/nixos-raspberrypi's raspberry-pi-5.base module sets enable_uart=1
# and selects the rpi5 kernel + nvme initrd module. It does NOT auto-emit
# the directives below (verified iter-1 FC V-9). We add them via the
# upstream hardware.raspberry-pi.config attrsOf submodule API.
#
# The `all` section name is convention; the upstream type is attrsOf, not
# enum-keyed. `all` is the canonical shared-config section.

{ config, lib, pkgs, ... }:

{
  hardware.raspberry-pi.config.all = {
    options = {
      auto_initramfs = { enable = true; value = 1; };

      # PoE+ HAT delivers via 40-pin header; Pi-OS power detection clips
      # USB to 600 mA without this. Without enough USB current, the
      # HYPERION-ID stick may fail to enumerate at boot. Pi Expert R5.
      usb_max_current_enable = { enable = true; value = 1; };
    };

    base-dt-params = {
      # NVMe boot requires the M.2 PCIe slot enabled. `nvme` is the alias
      # of `pciex1`. Pi 5 EEPROM applies this automatically when booting
      # from NVMe, but it's good belt-and-suspenders to set it explicitly.
      nvme = { enable = true; };

      # PCIe Gen 3 overclock from spec Gen 2. Pi Expert R2 notes some
      # drives/HATs are unstable at Gen 3. Override per-host by setting
      # `value = 2;` in that host's .nix file if a specific drive
      # misbehaves.
      pciex1_gen = { enable = true; value = 3; };
    };
  };

  # ── Bootloader mode ────────────────────────────────────────────────────────
  # `kernelboot` is the Pi 5 default in nvmd/nixos-raspberrypi.
  # Rollback under this mode requires installer-SD recovery (no boot menu).
  # If we find this insufficient in Phase 2+, switch to `uboot` here and
  # re-test (§J open item #6 — see FINAL.md). Reversible by one line.
  boot.loader.raspberry-pi.bootloader = lib.mkDefault "kernelboot";

  # ── No kernel= directive ───────────────────────────────────────────────────
  # The kernelboot builder stages the active generation's kernel as
  # literal `kernel.img` in the FAT firmware partition. The Pi 5 EEPROM
  # (BCM2712) boots that by default. Do NOT add `kernel=kernel_2712.img`
  # — that filename is a Debian/Pi-OS convention and does not apply here
  # (verified iter-2 PI-3).
}
