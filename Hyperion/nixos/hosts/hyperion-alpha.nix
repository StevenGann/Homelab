# hyperion-alpha — first Phase 1 validation node.
# 8 GB. IP 192.168.10.101.

{ ... }:

{
  networking.hostName = "hyperion-alpha";

  # k3s per-host metadata. nodeLabel / nodeTaint flow into the upstream
  # services.k3s module's first-class options — no shell wrapper around
  # ExecStart (rejected per iter-2 IAC-1).
  services.k3s.nodeLabel = [
    "topology.kubernetes.io/zone=hyperion"
    # Phase 1 marker — kept until alpha is no longer the active test node.
    "hyperion.lab/phase1-validator=true"
  ];

  services.k3s.nodeTaint = [];
}
