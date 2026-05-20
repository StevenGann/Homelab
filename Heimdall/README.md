# Heimdall

Edge-services host for the Homelab. One x86 box that runs the LAN's:

- **Internal DNS** — Technitium DNS Server (forwarder + ad/malware filter + authoritative `.lab` zone)
- **HTTPS reverse proxy + L4 router** — Caddy v2.11.3 with the `caddy-l4` plugin (internal CA for `*.lab` hostnames)
- **Container management UI** — Komodo Core v2.2.0 (per-container terminal, audit log, Git-driven deploys)
- **Centralized log shipper** — `systemd-journal-upload` to Monolith

> **Status:** deployed and operational (May 2026).
> Phase 2 acceptance gate passed; LAN-side DNS pointer (UCG DHCP option 6) is the
> only piece left for full LAN integration.

## Read the manual

**→ [`docs/manual/`](docs/manual/README.md)** is the user manual. Start there.

Quick links:

- **[Manual index](docs/manual/README.md)** — table of contents
- **[Architecture](docs/manual/01-architecture.md)** — what Heimdall is, with diagrams
- **[Components](docs/manual/02-components.md)** — per-tool reference
- **[Deployment](docs/manual/03-deployment.md)** — `bash Heimdall/scripts/deploy.sh` walkthrough
- **[Daily operations](docs/manual/04-operations.md)** — recipe-style how-tos
- **[Secrets (SOPS+age)](docs/manual/05-secrets.md)** — encrypted-secrets workflow
- **[Troubleshooting](docs/manual/06-troubleshooting.md)** — symptoms + fixes from the real install
- **[Reference](docs/manual/07-reference.md)** — cheatsheet (paths, ports, commands)

Imperative runbooks (executable sequences) live under **[`docs/runbooks/`](docs/runbooks/)** and are linked from the manual chapters where relevant.

## Quick reference

| | |
|---|---|
| Static IP | `192.168.10.4` |
| SSH | `ssh owner@192.168.10.4` |
| Deploy | `bash Heimdall/scripts/deploy.sh` (from workstation) |
| Komodo UI | `https://komodo.lab` (CA-trusted client) or `http://192.168.10.4:9120` via SSH tunnel |
| Technitium UI | `http://192.168.10.4:5380` (LAN-direct) |
| Repo on host | `/opt/Homelab/` |
| Decrypt a secret | `sops --decrypt Heimdall/secrets/env.sops.env` (workstation) |

## Hardware

| Component | Spec |
|---|---|
| CPU | Xeon E5-2690, 28 cores @ 3.5 GHz |
| RAM | 32 GB |
| NICs | 4 × 2.5 GbE, 2 × 10 GbE (only one 2.5G connected in v1) |
| OS | Ubuntu Server 26.04 LTS |

## Where the design history lives

- **Planning decisions log:** [`docs/design/heimdall-planning.md`](../docs/design/heimdall-planning.md)
- **First pipeline run (initial design):** [`docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/FINAL.md`](../docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/FINAL.md)
- **Second pipeline run (finalize):** [`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/FINAL.md`](../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/FINAL.md)

The manual is forward-looking ("here's what to do"). The pipeline runs are the historical record ("here's why we picked this").
