# Heimdall User Manual

> The conceptual + reference companion to the imperative
> [`runbooks/`](../runbooks/). This is what you read to **understand** Heimdall;
> the runbooks are what you read to **execute** a sequence of steps.

## What's in this manual

| Chapter | Use when you need to… |
|---|---|
| [01 — Architecture](01-architecture.md) | …understand what Heimdall is, where it fits in the homelab, and what each piece does. Start here. |
| [02 — Components](02-components.md) | …look up a specific tool (Technitium, Caddy, Komodo, MongoDB, Periphery, host services). Per-component purpose, configuration, access, and common tasks. |
| [03 — Deployment & reconstruction](03-deployment.md) | …deploy Heimdall, redeploy after a config change, or rebuild from scratch after hardware failure. Walks through `deploy.sh`. |
| [04 — Daily operations](04-operations.md) | …do a specific task: add a new HTTPS service, add a DNS record, block a domain, check logs, restart a container. Recipe-style. |
| [05 — Secrets (SOPS+age)](05-secrets.md) | …generate, rotate, decrypt, or recover encrypted secrets. The age key is the master of secrets — read this before touching it. |
| [06 — Troubleshooting](06-troubleshooting.md) | …a symptom-first index of things that have gone wrong (and why). Includes the gotchas from the May 2026 install. |
| [07 — Reference](07-reference.md) | …a cheatsheet: file paths, port map, env vars, scripts, runbooks. Skim this before going deep anywhere else. |

The **runbooks** under [`runbooks/`](../runbooks/) are linked from chapters where relevant. Each runbook is an executable sequence; each manual chapter explains the *why* behind the *what*.

## Quick start — the 30-second version

You're sitting at your workstation, Heimdall is already deployed, and you want to do something.

| I want to… | Go to |
|---|---|
| See what's running on Heimdall | Open Komodo at `https://komodo.lab` |
| Manage DNS records | Open Technitium at `http://192.168.10.4:5380` |
| Redeploy after editing compose / config | `bash Heimdall/scripts/deploy.sh` (workstation) |
| Add a new HTTPS service routed through Caddy | [04 — Daily operations → "Add an HTTPS route"](04-operations.md#add-an-https-route) |
| Add a custom DNS record (`.lab` zone) | Edit `RECORDS=()` in `Heimdall/scripts/seed-zones.sh`, commit, redeploy. Or use Technitium UI directly. |
| Look up a password / secret | `sops --decrypt Heimdall/secrets/env.sops.env` on the workstation |
| See what broke after an edit | [06 — Troubleshooting](06-troubleshooting.md) |
| Rebuild Heimdall from scratch | [`runbooks/reconstruction.md`](../runbooks/reconstruction.md) |

## Conventions used in this manual

- **`192.168.10.4`** is Heimdall's static IP on the LAN. Substitute your own if it differs.
- **`192.168.10.247`** is Akasha (TrueNAS host, log sink).
- **`192.168.10.1`** is the UCG (gateway, DHCP).
- **`heimdall.lab` / `komodo.lab` / `technitium.lab`** etc. are internal hostnames served by Heimdall's own Technitium DNS. They resolve only when DHCP option 6 points at Heimdall or you've added an `/etc/hosts` override on your client.
- **`owner`** is the operator user account on Heimdall (and on the workstation).
- **`workstation`** = your laptop / dev machine. **`Heimdall`** = the rack server at `192.168.10.4`.
- Code blocks marked `# On workstation:` or `# On Heimdall:` indicate where to run a command.
- All file paths under `Heimdall/...` are repo-relative. Paths under `/opt/Homelab/Heimdall/...` are on the deployed host.

## Audience

Someone who needs to operate, modify, or rebuild Heimdall. Assumes Linux comfort (systemd, Docker Compose, basic networking), but does not assume prior familiarity with the specific tools (Caddy, Technitium, Komodo, SOPS) — each is introduced where it appears.

Where deeper documentation exists upstream, the manual links out instead of duplicating it.

## Where this manual stops

This is the **operational** manual. The **design history** — how the team arrived at this stack, why Komodo over Dockge, why Technitium over AdGuard, etc. — lives in:

- [`docs/design/heimdall-planning.md`](../../../docs/design/heimdall-planning.md) — the planning decisions log.
- [`docs/pipeline-runs/`](../../../docs/pipeline-runs/) — the two pipeline runs (initial design + finalize) with their full debate records.

The manual is forward-looking. The pipeline runs are the historical record.
