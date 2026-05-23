# hyperion-delta — 8 GB Pi 5. IP 192.168.10.104.

{ ... }:

{
  networking.hostName = "hyperion-delta";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
