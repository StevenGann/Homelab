# Network Layout

> **Verified against the live network 2026-09-05.** This file previously
> described Akasha as the k3s control plane and image server, and node
> replacement as "move the cidata USB stick" — both were left over from the
> pre-NixOS Debian era and are wrong. The control plane moved to Heimdall on
> 2026-05-24; the identity/cidata USB model is retired (ADR-0001).
>
> The repo-wide map lives in [`README.md`](../../README.md#network) and
> [`CLAUDE.md`](../../CLAUDE.md#network-reference). This file is the
> Hyperion-focused view.

## Homelab VLAN — 192.168.10.0/24

Single flat VLAN. The UniFi UCG (`.1`) is the gateway and the **only** DHCP
server; every Hyperion node address is a DHCP reservation by MAC, so power-on
order does not determine IP order.

### Reserved ranges

| Range | Purpose |
|-------|---------|
| `.1` | Gateway (UCG), DHCP server for all VLANs |
| `.4` | Heimdall — edge services + k3s control plane |
| `.10–.99` | MetalLB LoadBalancer pool (`homelab-pool`, `autoAssign: true`) |
| `.101–.110` | Hyperion Pi nodes (UCG reservations) |
| `.129+` | UCG DHCP dynamic range |
| `.144` | Thoth (GPU compute) — **powered off** as of 2026-09-05 |
| `.147` | Home Assistant (`:8123`) |
| `.180` | APC AP7900 PDU (Telnet CLI on `:23`) |
| `.201` | Synology NAS |
| `.230` | owner-thinkpad (operator workstation / jump box) |
| `.231` | HDHomeRun tuner |
| `.247` | Akasha (TrueNAS Scale) |

`.179`, `.191`, `.241` and `.254` also answer ICMP but are not managed from this
repo.

### Node roster

All ten are NixOS 25.11 on NVMe, `Ready` as k3s workers (v1.34.5+k3s1), labelled
`topology.kubernetes.io/zone=hyperion`.

| Hostname | IP | Node-specific config |
|----------|----|----------------------|
| hyperion-alpha   | 192.168.10.101 | label `hyperion.lab/phase1-validator=true` |
| hyperion-beta    | 192.168.10.102 | 4 GB — taint `hyperion.lab/memory-tier=4gb:PreferNoSchedule` |
| hyperion-gamma   | 192.168.10.103 | 4 GB — taint `hyperion.lab/memory-tier=4gb:PreferNoSchedule` |
| hyperion-delta   | 192.168.10.104 | |
| hyperion-epsilon | 192.168.10.105 | |
| hyperion-zeta    | 192.168.10.106 | |
| hyperion-eta     | 192.168.10.107 | |
| hyperion-theta   | 192.168.10.108 | |
| hyperion-iota    | 192.168.10.109 | |
| hyperion-kappa   | 192.168.10.110 | |

Per-host divergence is declared in
[`Hyperion/nixos/hosts/<hostname>.nix`](../nixos/hosts/) and baked into that
host's closure at build time. The name↔IP map that the provisioning scripts read
is [`Hyperion/inventory.yaml`](../inventory.yaml).

> **Replacing a node:** update the MAC in the UCG DHCP reservation for that
> hostname, then run `./setup-hyperion-node.sh --name hyperion-<greek>` from a
> stock Raspberry Pi OS bootstrap SD. There is no identity USB to move. Full
> procedure: [`runbooks/replace-dead-node.md`](runbooks/replace-dead-node.md).

### Ports the nodes expose

| Port | What |
|------|------|
| `22` | SSH — user `owner`, key-only. Reachable from `192.168.0.0/24` as well as the lab VLAN. |
| `10250` | kubelet API |

Node firewalls are disabled (`networking.firewall.enable = false`); pod traffic
is k3s-managed.

### What the nodes talk to

| Target | Purpose |
|--------|---------|
| `192.168.10.4:6443` | k3s API — agent registration |
| `192.168.10.4:8472/udp` | Flannel VXLAN — pod network |
| `192.168.10.247:2049` | Akasha NFS — the media/app exports |
| `192.168.10.4:19532` | `systemd-journal-upload` sink — **the sink is not running**, so this unit restarts continuously on every node. Either start the `Heimdall/hyperion/` stack or disable the unit. |
