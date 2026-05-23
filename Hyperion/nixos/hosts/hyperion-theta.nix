# hyperion-theta — 8 GB Pi 5. IP 192.168.10.108.

{ ... }:

{
  networking.hostName = "hyperion-theta";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
