# Heimdall

Edge services host for the Homelab. Single physical box that will sit between the upstream UniFi switch and the two internal switch fabrics, providing:

- **Reverse proxy** — TLS termination and HTTP routing into the cluster
- **Load balancer** — north–south traffic distribution to k3s services on Hyperion / Monolith
- **DNS** — authoritative records for the Homelab and recursive resolution for LAN clients

> **Status:** tech stack finalized 2026-05-17 (DEVELOPMENT pipeline `20260517T213331Z-dev-heimdall-finalize`, 5 YAE / 0 NAY; supersedes the earlier `20260517T183851Z-dev-heimdall-tech-stack` run). IaC not yet written. **Authoritative design:** [`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md`](../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md). Known concerns / implementation punch list: [`FINAL.md`](../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/FINAL.md). Planning log: [`docs/design/heimdall-planning.md`](../docs/design/heimdall-planning.md).
>
> **Approved stack:** **Technitium DNS Server v15** (DNS+filter+`.lab` zone+CNAME-cloaking) + **Caddy v2.11.3** with `caddy-l4` plugin (HTTPS+ACME+L4) + **Komodo v2.2.0 Core+MongoDB** (Compose GUI with per-container terminal). Plus Komodo **Periphery** as a host systemd binary. **No MetalLB** — Caddy fans out to per-Pi-node NodePorts with health checks. Internal CA for `.lab` by default. Ubuntu Server 26.04 LTS.

---

## Hardware

| Component | Spec |
|-----------|------|
| CPU | Xeon E5-2690, 28 cores @ 3.5 GHz |
| RAM | 32 GB |
| NICs | 4 × 2.5 GbE, 2 × 10 GbE |
| OS | Ubuntu Server 26.04 LTS (clean install) |

## NIC assignment

See [`docs/network-layout.md`](docs/network-layout.md) for the full table. Summary:

| NIC | Speed | Connects to |
|-----|-------|-------------|
| 1 | 2.5 GbE | UniFi switch (upstream / north) |
| 2 | 2.5 GbE | 24-port gigabit switch (Hyperion + small appliances) |
| 3 | 10 GbE | 10 GbE switch (Monolith + compute servers) |
| 4 | 2.5 GbE | unassigned |
| 5 | 2.5 GbE | unassigned |
| 6 | 10 GbE | unassigned |

## Directory layout

```
Heimdall/
├── README.md              # this file
└── docs/
    ├── network-layout.md  # NIC-to-network mapping, IP plan
    └── runbooks/          # operational runbooks (to be added)
```

IaC artifacts (Ansible, Packer/cloud-init, container compose, etc.) will be added under this directory as the tech stack is decided.
