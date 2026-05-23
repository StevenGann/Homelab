# installer/installer.nix — the SD card / NVMe installer image.
#
# When the operator runs `nix build .#installerImage`, this is the system
# that produces the .img file. The image is identical across all 10
# nodes — per-host divergence happens after first boot via Colmena push
# from the workstation.
#
# Workflow on first install per node:
#   1. Workstation: nix build .#installerImage
#   2. Workstation: zstd -d result/sd-image/*.img | sudo dd of=/dev/sdX
#      (sdX = a USB-to-NVMe adapter, or a blank NVMe in a USB enclosure)
#   3. Move NVMe into the Pi
#   4. Insert HYPERION-ID identity USB
#   5. Power on
#   6. Pi boots NixOS from NVMe; apply-identity reads USB; k3s registers
#
# No nixos-anywhere, no SD card boot, no kexec, no in-place reflash.

{ config, lib, pkgs, ... }:

{
  system.stateVersion = "25.11";

  # Minimal user for any-recovery SSH (in case identity-USB isn't present
  # on a brand-new node).
  users.users.owner = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "imaging";   # changed by first apply-identity
  };

  services.openssh.enable = true;

  # The bare system — workers customize themselves via Colmena pushes
  # from the workstation. The installer image just needs to boot, get a
  # DHCP lease, and accept the first Colmena deploy.
  environment.systemPackages = with pkgs; [ vim htop ];

  networking.useDHCP = true;
  networking.firewall.enable = false;
}
