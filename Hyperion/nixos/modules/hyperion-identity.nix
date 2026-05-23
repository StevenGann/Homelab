# hyperion-identity.nix — per-node identity from the HYPERION-ID USB stick.
#
# The USB carries data, not code:
#   /identity.env          — KEY=VALUE shell file (hostname, node IP)
#   /age-key.txt           — sops-nix age private key (per-node unique)
#   /secrets/              — persistent SSH host keys
#   /meta/schema-version   — integer (currently "2"); refuses unknown
#
# Flow at boot:
#   1. Stage-1 initrd mounts /var/lib/hyperion-id (neededForBoot = true)
#   2. activationScripts.hyperionIdentitySchemaCheck verifies the schema-
#      version integer
#   3. sops-nix reads sops.age.keyFile from /var/lib/hyperion-id/age-key.txt
#      and decrypts secrets at activation
#   4. apply-identity.service stages /run/hyperion/identity.env from the USB
#   5. k3s reads --token-file from sops-nix path and --environment-file
#      from /run/hyperion/identity.env

{ config, lib, pkgs, ... }:

{
  # ── USB mount (stage-1 initrd) ─────────────────────────────────────────────
  # neededForBoot = true is non-negotiable — without it, sops-nix activation
  # can fire before the USB mount and fail to decrypt (per iter-1 FC V-6).
  fileSystems."/var/lib/hyperion-id" = {
    device = "/dev/disk/by-label/HYPERION-ID";
    fsType = "ext4";
    options = [ "ro" "nofail" "x-systemd.device-timeout=15s" ];
    neededForBoot = true;
  };

  # Stage-1 initrd must include modules to read a USB-attached ext4 volume.
  # The Pi 5 base module brings in nvme; we add USB-storage + ext4.
  boot.initrd.availableKernelModules = [
    "usb-storage"
    "uas"
    "ext4"
  ];

  # ── Schema-version fail-fast ───────────────────────────────────────────────
  # Aborts boot with a journal-visible FATAL on mismatch. The node stays
  # SSH-reachable on DHCP, but k3s and identity are blocked from start.
  system.activationScripts.hyperionIdentitySchemaCheck = {
    text = ''
      expected="2"
      actual="$(${pkgs.coreutils}/bin/cat /var/lib/hyperion-id/meta/schema-version 2>/dev/null || echo missing)"
      if [ "$actual" != "$expected" ]; then
        echo "FATAL: HYPERION-ID schema-version mismatch (expected $expected, got $actual)" >&2
        exit 1
      fi
    '';
    deps = [ ];
  };

  # ── sops-nix wires the per-node age key from the USB ───────────────────────
  # Secrets in the repo under Hyperion/nixos/secrets/ are decrypted with
  # this key at activation time and land in /run/secrets/.
  sops = {
    age.keyFile = "/var/lib/hyperion-id/age-key.txt";
    defaultSopsFile = ../secrets/common.yaml;

    secrets = {
      k3s-token = {
        # k3s reads this via services.k3s.tokenFile = config.sops.secrets.k3s-token.path
        # (canonical sops-nix idiom; verified iter-1 FC V-22).
        owner = "root";
        mode = "0400";
      };
    };
  };

  # ── Persistent SSH host keys ───────────────────────────────────────────────
  # Copy the per-node host key from the USB to /etc/ssh on every boot.
  # This is what makes known_hosts stable across NVMe re-flashes.
  system.activationScripts.hyperionSshHostKeys = {
    text = ''
      if [ -f /var/lib/hyperion-id/secrets/ssh_host_ed25519_key ]; then
        ${pkgs.coreutils}/bin/install -m 0600 \
          /var/lib/hyperion-id/secrets/ssh_host_ed25519_key \
          /etc/ssh/ssh_host_ed25519_key
        ${pkgs.coreutils}/bin/install -m 0644 \
          /var/lib/hyperion-id/secrets/ssh_host_ed25519_key.pub \
          /etc/ssh/ssh_host_ed25519_key.pub
      fi
    '';
    deps = [ "hyperionIdentitySchemaCheck" ];
  };

  # ── apply-identity.service — stages /run/hyperion/identity.env ─────────────
  # Reads HYPERION_HOSTNAME, HYPERION_NODE_IP from the USB's identity.env
  # and stages them at /run/hyperion/identity.env for services.k3s to source.
  systemd.services.apply-identity = {
    description = "Stage Hyperion identity from HYPERION-ID USB";
    wantedBy = [ "multi-user.target" ];
    before = [ "k3s.service" "network-online.target" ];
    after = [ "var-lib-hyperion\\x2did.mount" ];
    requires = [ "var-lib-hyperion\\x2did.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ${pkgs.coreutils}/bin/install -d -m 0755 /run/hyperion
      ${pkgs.coreutils}/bin/install -m 0644 /var/lib/hyperion-id/identity.env /run/hyperion/identity.env

      # Apply hostname at runtime. networking.hostName is "" in the base
      # module so this runtime value wins.
      # shellcheck disable=SC1091
      . /run/hyperion/identity.env
      ${pkgs.systemd}/bin/hostnamectl set-hostname "$HYPERION_HOSTNAME"
    '';
  };

  # ── Hostname-resolution fallback ───────────────────────────────────────────
  # Until apply-identity runs, /etc/hostname is empty. Make sure nothing
  # crashes on that briefly.
  systemd.services.systemd-hostnamed.after = [ "apply-identity.service" ];
}
