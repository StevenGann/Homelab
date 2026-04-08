# Network Layout

## Homelab VLAN — 192.168.10.0/24

All Hyperion infrastructure lives here.

### Reserved Ranges

| Range | Purpose |
|-------|---------|
| `.1` | Gateway (UCG) |
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion Pi nodes (static, assigned in UCG) |
| `.129+` | DHCP dynamic range (UCG) |
| `.247` | Monolith (TrueNAS Scale) |

### Node Roster

| Hostname | IP | Notes |
|----------|----|-------|
| hyperion-alpha   | 192.168.10.101 | |
| hyperion-beta    | 192.168.10.102 | |
| hyperion-gamma   | 192.168.10.103 | |
| hyperion-delta   | 192.168.10.104 | |
| hyperion-epsilon | 192.168.10.105 | |
| hyperion-zeta    | 192.168.10.106 | |
| hyperion-eta     | 192.168.10.107 | |
| hyperion-theta   | 192.168.10.108 | |
| hyperion-iota    | 192.168.10.109 | |
| hyperion-kappa   | 192.168.10.110 | |

> When replacing a node: move the cidata USB stick to the replacement Pi, update the MAC
> in the UCG DHCP reservation for that hostname, and boot. Everything else stays the same.

### Key Hosts

| Host | IP | Role |
|------|----|------|
| Monolith | 192.168.10.247 | TrueNAS Scale — k3s control plane, TFTP, image server |
| UCG | 192.168.10.1 | Router, DHCP server for all VLANs |
