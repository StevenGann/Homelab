# hyperion-iota — 8 GB Pi 5. IP 192.168.10.109.

{ ... }:

{
  networking.hostName = "hyperion-iota";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
