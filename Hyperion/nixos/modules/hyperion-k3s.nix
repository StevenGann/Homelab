# hyperion-k3s.nix — k3s agent wired to the Monolith server.
#
# Per-host node labels and taints come from hosts/<hostname>.nix via the
# first-class services.k3s.nodeLabel and services.k3s.nodeTaint options.
# Token is sops-nix-decrypted via the per-node age key on the USB.
#
# k3s server endpoint: 192.168.10.247:6443 (Monolith, unchanged).
# Note: the *flashing-services* moved to Heimdall (.4) per the prior
# pipeline, but the k3s control plane (server) is still on Monolith.

{ config, lib, pkgs, ... }:

{
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.10.247:6443";

    # Canonical sops-nix idiom (iter-1 FC V-22). Sops-nix exposes the
    # decrypted-path as a string at evaluation; k3s reads it at start.
    tokenFile = config.sops.secrets.k3s-token.path;

    # Runtime per-host metadata (hostname, IP) flows through this env file.
    # Populated by apply-identity.service from the HYPERION-ID USB.
    environmentFile = "/run/hyperion/identity.env";

    # nodeLabel and nodeTaint are intentionally NOT set in this base
    # module — they're per-host. See hosts/hyperion-<greek>.nix for
    # the actual values.
  };

  # k3s should NOT start before apply-identity has staged identity.env and
  # sops-nix has decrypted secrets.
  systemd.services.k3s = {
    after = [ "apply-identity.service" "sops-install-secrets.service" ];
    requires = [ "apply-identity.service" ];
  };

  # Required sysctls for k3s pod networking on Pi 5.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };
}
