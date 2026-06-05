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

  # Explicitly advertise the hostname (DHCP option 12). NOTE: NixOS's default
  # dhcpcd.conf ALREADY emits `hostname`, so this is belt-and-suspenders, not a
  # fix — every node has advertised hyperion-<greek> since first boot. The UCG
  # showing "Homelab-Bootstrap" is a UniFi client-name STICKINESS quirk: it
  # caches the name first seen for each MAC (the RasPi-OS bootstrap phase) and
  # does not overwrite it when the DHCP hostname later changes. The cure is
  # controller-side (clear the client's cached name in UniFi), not here.
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

  # ── Nix store hygiene ──────────────────────────────────────────────────────
  # These workers have a 32GB NVMe; /nix/store grows unbounded across Colmena
  # generations and will trip the kubelet's DiskPressure eviction threshold
  # (hyperion-theta hit it 2026-06-05 — /nix/store had grown to 27GB; a manual
  # `nix-collect-garbage -d` freed 20GB). Collect weekly, deleting only
  # generations older than 7 days so a recent rollback target survives.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

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

  # NFS client support for the *arr media stack: mounts Akasha (192.168.10.247)
  # NFS exports into k3s pods. This single option pulls in nfs-utils (the
  # mount.nfs/mount.nfs4 helper the kubelet invokes), rpcbind, rpc-statd and
  # nfs-idmapd — the bare `environment.systemPackages = [ pkgs.nfs-utils ]` form
  # is NOT equivalent (it omits the rpcbind/statd services). Live day-2 change,
  # applied via `colmena apply` with no reboot. See docs/design/arr-stack-plan.md §0.5.
  boot.supportedFilesystems = [ "nfs" ];

  # ── Longhorn distributed block storage ──────────────────────────────────────
  # Longhorn's stable (v1) data engine attaches replicas over iSCSI: the
  # longhorn-manager pod calls the HOST's iscsiadm via nsenter, and each replica
  # is exposed as a local iSCSI target the kubelet mounts. Without a running
  # iscsid + the iscsi_tcp module, volume attach fails ("iscsiadm: not found" /
  # "failed to login to target"). services.openiscsi provides iscsiadm on PATH,
  # the iscsid socket, and an initiator IQN. Live day-2 change, no reboot.
  # See docs/runbooks/longhorn-storage.md.
  services.openiscsi = {
    enable = true;
    # Per-node initiator name. config.networking.hostName is set in
    # hosts/<hostname>.nix and resolved at build time.
    name = "iqn.2026-06.lab.homelab:${config.networking.hostName}";
  };

  # Longhorn stores replica data under defaultDataPath. The 32G root partition
  # already trips kubelet DiskPressure (shared with /nix/store); the disko layout
  # carves the NVMe remainder (~200G) into nvme0n1p3 at /mnt/node-storage. Point
  # Longhorn there (matched by the default-data-path setting in the Longhorn
  # ConfigMap). tmpfiles guarantees the dir exists before longhorn-manager's
  # first disk scan. See disko/nvme-layout.nix.
  systemd.tmpfiles.rules = [
    "d /mnt/node-storage/longhorn 0755 root root -"
  ];
}
