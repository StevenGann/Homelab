# installer/installer.nix — the live SD-card installer for Hyperion workers.
#
# This is NOT the installed system. It is a thin live environment that boots
# from a microSD card and waits, SSH-reachable, so the operator workstation
# can drive a remote NixOS install onto the node's blank NVMe via
# nixos-anywhere. It is identical across all 10 nodes.
#
# Why an SD installer and not nixos-anywhere's usual kexec bootstrap:
#   kexec is broken on the Raspberry Pi (nixos-anywhere #183 "missing
#   /proc/kcore"; nixos-raspberrypi does not support kexec). The nixos-
#   anywhere docs therefore say ARM targets must "boot from a NixOS
#   installer image". This is that image.
#
# Lifecycle per node:
#   1. Operator flashes this image to a microSD (once; identical for all)
#      and inserts it at hardware-assembly time.
#   2. EEPROM BOOT_ORDER = 0xf16 (NVMe -> SD -> loop): a blank NVMe falls
#      through to this SD installer; an installed NVMe wins and the SD is
#      ignored.
#   3. Pi boots this installer from SD, gets a DHCP lease, runs sshd.
#   4. Workstation: ./flash-node.sh <ip> hyperion-<name>  -> nixos-anywhere
#      partitions the NVMe (disko), builds the per-host closure ON THIS
#      installer (--build-on-remote, pulling from Cachix), injects the age
#      key + SSH host keys (--extra-files), and reboots.
#   5. EEPROM now finds a valid NVMe -> boots NixOS. SD stays resident,
#      harmless, available for re-flash/recovery.
#
# The flake installer assembly must NOT import disko/nvme-layout.nix — that
# defines / as the NVMe, which is wrong for an SD-resident live system.

{ config, lib, pkgs, ... }:

let
  # Operator SSH public key — same value as hyperion-base.nix and the
  # NODE_SSH_PUBLIC_KEY GitHub Actions secret. nixos-anywhere connects as
  # root@<ip> using this key.
  operatorKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRlnV15+a4pjzB8BqGq33LaOk9sBtLyaaE+WqWLxUIy owner@owner-thinkpad";
in
{
  # NOTE: no system.stateVersion here. The installer profile / rpi full-config
  # own it; an installer is ephemeral, and a second definition risks a
  # mkDefault-vs-mkDefault conflict.

  # ── Access ───────────────────────────────────────────────────────────────
  # root key-only login: nixos-anywhere defaults to root@target and needs to
  # partition disks. This is an ephemeral live environment on the LAN, so a
  # key-authenticated root login here is acceptable and simplest.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [ operatorKey ];

  # Convenience `owner` for manual SSH-in during bring-up/debug. (The
  # installer profile already sets passwordless wheel sudo via
  # mkImageMediaOverride, so we don't set security.sudo here.)
  users.users.owner = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ operatorKey ];
  };

  # ── Nix: flakes + the rpi5 binary cache ────────────────────────────────────
  # --build-on-remote builds the per-host closure here on the Pi. Enabling
  # the nixos-raspberrypi Cachix substituter means the rpi5 kernel and ~all
  # of the closure are substituted, not compiled, on the node.
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [
      "https://cache.nixos.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
    # nixos-anywhere copies the flake and invokes nix as root over SSH.
    trusted-users = [ "root" "owner" ];
  };

  # ── Networking ─────────────────────────────────────────────────────────────
  # The nixos-installer profile manages networking via NetworkManager (DHCP
  # by default) and opens sshd's port — so no networking.* overrides here.
  # Setting networking.useDHCP would conflict with NetworkManager's own
  # definition (CI: "networking.useDHCP has conflicting definition values").

  # ── Tools the install needs / operator wants ───────────────────────────────
  # disko + nixos-install come from nixos-anywhere's own closure; these are
  # for manual inspection and recovery from an SSH session.
  environment.systemPackages = with pkgs; [
    vim
    htop
    parted
    gptfdisk
    nvme-cli
    git
  ];
}
