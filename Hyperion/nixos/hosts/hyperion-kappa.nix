# hyperion-kappa — 8 GB Pi 5. IP 192.168.10.110.

{ ... }:

{
  networking.hostName = "hyperion-kappa";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
