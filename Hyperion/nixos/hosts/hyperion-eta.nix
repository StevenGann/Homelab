# hyperion-eta — 8 GB Pi 5. IP 192.168.10.107.

{ ... }:

{
  networking.hostName = "hyperion-eta";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
