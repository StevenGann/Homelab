# Heimdall — Network Layout

Heimdall is multi-homed: it has one NIC into each of the three switch fabrics in the Homelab, plus three unassigned ports held in reserve. Subnet routing, VLAN tagging, and IP assignments will be finalized during planning — this document records the physical wiring and intended role of each port.

## Physical NIC roster

The OS-side device names (`enp*` / `eno*`) are not yet captured; they will be filled in once Heimdall is racked and named via udev/netplan.

| # | Speed | Connects to | Role | OS name |
|---|-------|-------------|------|---------|
| 1 | 2.5 GbE | UniFi switch | Upstream / north (WAN-side of the lab) | TBD |
| 2 | 2.5 GbE | 24-port gigabit switch | Hyperion cluster + small appliances | TBD |
| 3 | 10 GbE | 10 GbE switch | Akasha + compute servers | TBD |
| 4 | 2.5 GbE | — | Reserve | TBD |
| 5 | 2.5 GbE | — | Reserve | TBD |
| 6 | 10 GbE | — | Reserve | TBD |

## Existing Homelab segments (for context)

From [`Hyperion/docs/network-layout.md`](../../Hyperion/docs/network-layout.md):

| Range | Purpose |
|-------|---------|
| `192.168.10.1` | UCG gateway |
| `192.168.10.10–.99` | MetalLB LoadBalancer pool |
| `192.168.10.101–.110` | Hyperion Pi nodes |
| `192.168.10.247` | Akasha |
| `192.168.10.129+` | DHCP dynamic range |

Today all infrastructure is on a single VLAN `192.168.10.0/24`. Heimdall introduces the first multi-NIC host in the repo; whether each fabric stays on the same `/24` or gets a dedicated subnet is an **open question** for planning.

## Open questions

These belong in [`docs/design/heimdall-planning.md`](../../docs/design/heimdall-planning.md), recorded here so the next conversation has them in front of it:

- **IP allocation per NIC.** Static addresses for ports 1–3, or some routed/bonded scheme?
- **VLAN strategy.** Stay flat on `192.168.10.0/24` everywhere, or carve out per-fabric subnets?
- **Default route.** Heimdall presumably defaults out NIC 1 (UniFi). Does it also act as a router between the gigabit and 10 GbE fabrics, or does the UCG continue to handle east–west?
- **DHCP authority.** UCG is the DHCP server today. If Heimdall takes over DNS, does it also become DHCP, or do those stay split?
- **MetalLB interaction.** A reverse proxy and a MetalLB pool both want to be the LAN-facing entry point. Which is canonical for which services?
- **Reserve ports.** Earmark for LACP/bond on existing roles, future fabrics, or out-of-band management?
