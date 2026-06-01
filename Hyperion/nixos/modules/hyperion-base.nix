# hyperion-base.nix — common configuration for every Hyperion worker.
#
# Per-host divergence (k3s labels/taints, per-node Pi 5 overrides) lives
# in hosts/<hostname>.nix. This module is identical across all 10 workers.

{ config, lib, pkgs, ... }:

{
  # ── System basics ──────────────────────────────────────────────────────────
  system.stateVersion = "25.11";

  # Hostname is the only piece of identity that comes from the USB at
  # activation time (via apply-identity.service in hyperion-identity.nix).
  # We leave networking.hostName unset and let the activation script
  # `hostnamectl set-hostname` from /var/lib/hyperion-id/identity.env.
  networking.hostName = lib.mkDefault "";

  time.timeZone = "Etc/UTC";

  # ── Networking ─────────────────────────────────────────────────────────────
  networking.useDHCP = true;          # UCG holds reservations .101..110 → MAC

  # Advertise the hostname (DHCP option 12) so the UCG/Technitium show
  # hyperion-<greek> instead of the stale "Homelab-Bootstrap". NixOS's dhcpcd
  # sends no hostname by default, so the UCG kept the name it learned during
  # the RasPi-OS bootstrap phase (observed 2026-06-01). `hostname` on its own
  # line tells dhcpcd to send the current system hostname.
  networking.dhcpcd.extraConfig = "hostname";

  # IPv6 disabled at runtime — the lab VLAN is v4-only by convention. No
  # firewall on workers; pod traffic is k3s-managed.
  networking.firewall.enable = false;
  networking.enableIPv6 = false;

  # ── Users ──────────────────────────────────────────────────────────────────
  # SSH-only access as `owner`. Password login disabled; key comes from
  # the sops-nix-decrypted authorized_keys (see hyperion-identity.nix).
  users.users.owner = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Operator's SSH public key — pinned here as the build-time source of
      # truth. Same value as NODE_SSH_PUBLIC_KEY GitHub Actions secret.
      # Rotated by editing this file and `colmena apply`.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRlnV15+a4pjzB8BqGq33LaOk9sBtLyaaE+WqWLxUIy owner@owner-thinkpad"
    ];
  };

  # Passwordless sudo for owner; no other privileged accounts.
  security.sudo.wheelNeedsPassword = false;

  # ── SSH ────────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
    # SSH host keys persist on the identity USB (see hyperion-identity.nix).
    # This eliminates known_hosts churn after re-imaging.
    hostKeys = lib.mkForce [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
  };

  # ── System packages ────────────────────────────────────────────────────────
  # Minimal — these are workers, not workstations. Anything not listed here
  # is one `nix-shell -p` away on the workstation.
  environment.systemPackages = with pkgs; [
    # Operator basics for SSH-in debug.
    vim
    htop
    iotop
    lsof
    tcpdump
    pciutils
    usbutils
    # k3s troubleshooting — actual k3s binary comes from services.k3s.
    jq
  ];

  # ── Boot ───────────────────────────────────────────────────────────────────
  # Pi 5 specifics live in hyperion-pi5.nix. Generic kernel-cmdline
  # additions can land here.
  boot.kernelParams = [
    "console=serial0,115200"
    "console=tty1"
    # The Raspberry Pi kernel ships the memory cgroup controller DISABLED by
    # default; without these k3s/containerd dies at start with
    # "failed to find memory cgroup (v2)" (observed on hyperion-alpha
    # 2026-06-01, first hardware boot). cpuset is added for kubelet QoS.
    # The Debian path set the equivalent in config.txt; the NixOS scaffold
    # had never been hardware-validated, so this was missing.
    "cgroup_enable=cpuset"
    "cgroup_enable=memory"
    "cgroup_memory=1"
  ];

  # cgroups v2 required by k3s on recent kernels.
  boot.kernelModules = [ "br_netfilter" "overlay" ];
}
