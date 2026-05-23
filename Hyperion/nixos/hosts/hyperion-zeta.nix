# hyperion-zeta — 8 GB Pi 5. IP 192.168.10.106.

{ ... }:

{
  networking.hostName = "hyperion-zeta";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
