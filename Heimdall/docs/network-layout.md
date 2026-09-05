# Heimdall — Network Layout

> **Status: this was a pre-deployment planning stub. Corrected against the live
> host on 2026-09-05.** The multi-fabric design below was never built — Heimdall
> ended up **single-homed**. The "open questions" at the bottom are answered and
> kept only as a record of what was considered.

## As-built (2026-09-05)

Heimdall has six physical ports but **only one is in use**:

| OS name | State | Address | Role |
|---------|-------|---------|------|
| `enp12s0` | UP | `192.168.10.4/24` (DHCP-configured, reserved at the UCG) | The single uplink — carries everything |
| `enp9s0` | down | — | MAC-pinned via netplan `set-name`, otherwise unused |
| `enp10s0`, `enp11s0` | down | — | Unused |
| `ens4f0`, `ens4f1` | down | — | Unused (10 GbE) |

Docker adds `br-e40b624bf5e4` (`172.19.0.1/16` — the k3s control-plane bridge,
the source of the flannel-VTEP problem in
[ADR-0002](../../docs/design/adr-0002-containerized-control-plane-networking.md)),
`br-de12adf0db38` (`172.18.0.1/16`) and a down `docker0`.

**There is no per-fabric subnetting and no routing role.** Everything stays flat
on `192.168.10.0/24` and the UCG continues to handle east–west. The tracked
`Heimdall/netplan/` config declares the static-IP intent; the running host is
configured by subiquity's `enp12s0: dhcp4: true` plus the UCG reservation.

> ⚠️ **SSH to Heimdall is not reachable from `192.168.0.0/24`.** ICMP, `:80`,
> `:443` and `:6443` cross the subnet boundary but `:22` does not. Use
> `owner-thinkpad` (`192.168.10.230`) as a `ProxyJump`. Akasha's sshd refuses
> TCP forwarding and will not work as a jump host.

## The original plan (not built)

Heimdall was to be multi-homed with one NIC into each of three switch fabrics,
plus three reserve ports:

| # | Speed | Connects to | Role | OS name |
|---|-------|-------------|------|---------|
| 1 | 2.5 GbE | UniFi switch | Upstream / north (WAN-side of the lab) | never assigned |
| 2 | 2.5 GbE | 24-port gigabit switch | Hyperion cluster + small appliances | never assigned |
| 3 | 10 GbE | 10 GbE switch | Akasha + compute servers | never assigned |
| 4 | 2.5 GbE | — | Reserve | — |
| 5 | 2.5 GbE | — | Reserve | — |
| 6 | 10 GbE | — | Reserve | — |

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

## Open questions — resolved

These were recorded in [`docs/design/heimdall-planning.md`](../../docs/design/heimdall-planning.md); the answers are what the lab actually does:

- **IP allocation per NIC.** *Moot* — one NIC (`enp12s0`) carries everything at `192.168.10.4`.
- **VLAN strategy.** **Flat.** Everything is on `192.168.10.0/24`; no per-fabric subnets were carved.
- **Default route.** Out `enp12s0` to the UCG. **Heimdall does not route** — the UCG handles all east–west.
- **DHCP authority.** **Split, as before.** The UCG remains the sole DHCP server. Heimdall took DNS only — and the DNS role itself is split two ways: **Pi-hole** answers the LAN on `:53` and forwards the `.lab` zone to **Technitium** on `127.0.0.1:5353`.
- **MetalLB interaction.** **Both, by service.** MetalLB pool IPs (`.10–.99`) are the canonical entry point for most cluster apps and their `*.lab` A records point straight at them. Caddy fronts only what needs TLS, auth, path routing or an off-cluster backend — currently `komodo`, `auth`, `pihole`, `technitium`, `alfred`, `immich`, `ignis`, `subwave`, `sharedirstat`, the Thoth AI trio, and `jf.stevengann.com` on `:7443`.
- **Reserve ports.** Unused. No bonding, no out-of-band management.
