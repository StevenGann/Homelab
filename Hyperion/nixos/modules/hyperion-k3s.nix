# hyperion-k3s.nix — k3s agent wired to the Heimdall control plane.
#
# Per-host node labels and taints come from hosts/<hostname>.nix via the
# first-class services.k3s.nodeLabel and services.k3s.nodeTaint options.
# Token is sops-nix-decrypted via the per-node age key on the USB.
#
# k3s server endpoint: https://192.168.10.4:6443 (Heimdall, containerized
# via Heimdall/k3s-control-plane/docker-compose.yml). The old endpoint at
# Akasha :247 is gone — Akasha's k3s server was broken and is being
# renovated to a pure-storage role once Hyperion is operational.
#
# Server image is pinned to rancher/k3s:v1.34.5-k3s1 to align with the
# k3s package nixpkgs nixos-25.11 ships for the workers. Same-minor
# server+worker means no version-skew workarounds are needed.

{ config, lib, pkgs, ... }:

{
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.10.4:6443";

    # Canonical sops-nix idiom (iter-1 FC V-22). Sops-nix exposes the
    # decrypted-path as a string at evaluation; k3s reads it at start.
    tokenFile = config.sops.secrets.k3s-token.path;

    # Hostname comes from the per-host closure (networking.hostName in
    # hosts/<hostname>.nix); the node IP is the UCG DHCP reservation, which
    # k3s auto-detects on the primary interface. No runtime env file.
    #
    # nodeLabel and nodeTaint are intentionally NOT set in this base
    # module — they're per-host. See hosts/hyperion-<greek>.nix for
    # the actual values.
  };

  # k3s must not start before sops-nix has decrypted the token. (The old
  # apply-identity.service ordering went away with the HYPERION-ID USB.)
  systemd.services.k3s = {
    after = [ "sops-install-secrets.service" ];
  };

  # Required sysctls for k3s pod networking on Pi 5.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };
}
