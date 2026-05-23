# hyperion-gamma — 4 GB Pi 5. IP 192.168.10.103.

{ ... }:

{
  networking.hostName = "hyperion-gamma";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
    "hyperion.lab/memory-tier=4gb"
  ];

  services.k3s.nodeTaint = [
    "hyperion.lab/memory-tier=4gb:PreferNoSchedule"
  ];
}
