# hyperion-beta — Phase 2 validation node (4 GB Pi 5).
# Memory-constraint surfacing for nixos-rebuild + workload sizing.
# IP 192.168.10.102.

{ ... }:

{
  networking.hostName = "hyperion-beta";

  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
    # 4 GB Pi 5; avoid scheduling memory-hungry workloads here.
    "hyperion.lab/memory-tier=4gb"
  ];

  # Scheduler hint that this node has reduced headroom. Workloads must
  # tolerate the taint explicitly.
  services.k3s.nodeTaint = [
    "hyperion.lab/memory-tier=4gb:PreferNoSchedule"
  ];
}
