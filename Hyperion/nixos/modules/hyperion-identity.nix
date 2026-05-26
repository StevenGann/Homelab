# hyperion-identity.nix — sops-nix secret decryption for each worker.
#
# The per-node age private key is injected onto the NVMe at install time by
# nixos-anywhere (--extra-files -> /var/lib/sops-nix/key.txt); it never
# enters the Nix store or git. SSH host keys are injected the same way to
# /etc/ssh. Node identity (hostname, k3s labels/taints) lives in the per-host
# closure (hosts/<hostname>.nix), and the node IP comes from the UCG DHCP
# reservation (.101..110) — nothing identity-bearing is on removable media.
#
# History: a HYPERION-ID USB previously carried the age key + identity.env at
# runtime (schema v2), mounted neededForBoot in stage-1 initrd. That model
# was retired with the move to the nixos-anywhere remote-flash flow — kexec
# is unavailable on the Pi, so installs run from a live SD installer and
# inject secrets via --extra-files. See docs/runbooks/remote-flash-a-node.md.

{ config, lib, pkgs, ... }:

{
  sops = {
    # Injected by `nixos-anywhere --extra-files` at install time. Present on
    # the NVMe root before first activation, and persists across day-2
    # `colmena apply` rebuilds (it lives outside the Nix store).
    age.keyFile = "/var/lib/sops-nix/key.txt";
    defaultSopsFile = ../secrets/common.yaml;

    secrets.k3s-token = {
      # k3s reads this via services.k3s.tokenFile in hyperion-k3s.nix.
      owner = "root";
      mode = "0400";
    };
  };
}
