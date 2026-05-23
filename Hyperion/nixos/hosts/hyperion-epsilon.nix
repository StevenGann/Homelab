# hyperion-epsilon — 8 GB Pi 5. IP 192.168.10.105.

{ ... }:

{
  networking.hostName = "hyperion-epsilon";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
  ];

  services.k3s.nodeTaint = [];
}
