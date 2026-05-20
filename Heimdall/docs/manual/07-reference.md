# 07 — Reference

> The cheatsheet. Quick-lookup tables for file paths, ports, scripts, env vars, runbooks, and pipeline-run artifacts.

## IPs and hostnames

| Resource | Address | Notes |
|---|---|---|
| Heimdall | `192.168.10.4` | Static, MAC-pinned netplan |
| UCG (gateway, DHCP, DNS bootstrap) | `192.168.10.1` | |
| Monolith (TrueNAS, journal sink) | `192.168.10.247` | journal-remote on `:19532` |
| Hyperion Pi nodes | `192.168.10.101–110` | UCG DHCP reservations |
| `komodo.lab` | `192.168.10.4` (CNAME-equivalent — A record direct) | Resolved by Technitium |
| Caddy CA root URL | `http://192.168.10.4/ca.crt` | LAN-only |

## Port map

| Port | Protocol | Service | Listener | Source allowed | Published from container |
|---|---|---|---|---|---|
| 22 | TCP | sshd | host | LAN | — |
| 53 | TCP+UDP | Technitium | host (host-net container) | LAN | `network_mode: host` |
| 80 | TCP | Caddy `/ca.crt` block | host (Caddy host-net) | LAN | `network_mode: host` |
| 443 | TCP+UDP | Caddy HTTPS + HTTP/3 | host | LAN + WAN (if forwarded) | `network_mode: host` |
| 853 | TCP | Technitium DoT (opt-in) | host | LAN | `network_mode: host` |
| 5380 | TCP | Technitium web UI | host | LAN | `network_mode: host` |
| 8120 | TCP | Komodo Periphery | host (`[::]:8120`) | `127.0.0.0/8` only via nftables | systemd binary, not container |
| 9120 | TCP | Komodo Core HTTP | `127.0.0.1` | LAN (for break-glass) | `127.0.0.1:9120:9120` |
| 25565 | TCP+UDP | Caddy L4 (Minecraft) | host | LAN + WAN (if forwarded) | `network_mode: host` |
| 19532 | UDP | journal-upload destination | outbound | — | host service |
| 27017 | TCP | MongoDB | bridge | bridge net only (Komodo Core) | not published |

## Repo layout — `Heimdall/`

```
Heimdall/
├── README.md                       — top-level summary
├── .sops.yaml                      — age recipient declaration
├── .env.example                    — env var template (not used at runtime)
├── docker-compose.yml              — 4-service Compose stack
├── secrets/
│   ├── env.sops.env                — SOPS-encrypted Komodo+Mongo creds
│   └── technitium-admin-pw.sops    — SOPS-encrypted Technitium admin password
├── caddy/
│   ├── Caddyfile                   — routing config (bind-mounted)
│   ├── data/                       — runtime: ACME, CA root, certs (bind-mounted)
│   ├── config/                     — runtime: Caddy state (bind-mounted)
│   └── image/
│       ├── Dockerfile              — custom image with caddy-l4 baked in
│       └── README.md               — image upgrade policy
├── technitium/
│   ├── config/                     — runtime: zones, blocklists, dns.config (bind-mounted)
│   ├── logs/                       — runtime: server logs (bind-mounted)
│   └── scripts/                    — (unused; seed-zones is in scripts/)
├── komodo-data/
│   ├── mongo-data/                 — runtime: MongoDB data files (bind-mounted)
│   ├── mongo-config/               — runtime: MongoDB config DB (bind-mounted)
│   ├── keys/                       — runtime: Komodo internal Ed25519 keys (bind-mounted)
│   ├── repos/                      — runtime: Git checkouts Komodo manages (bind-mounted)
│   └── backups/                    — runtime: Komodo's own backup output (bind-mounted)
├── netplan/
│   └── 01-uplink.yaml              — static IP, MAC-pinned NIC
├── hostconf/
│   ├── resolved-no-stub.conf       — systemd-resolved DNSStubListener=no
│   ├── nftables.conf               — host firewall ruleset
│   ├── journal-upload-monolith.conf — destination URL for systemd-journal-upload
│   └── docker-daemon.json          — Docker daemon config (journald, live-restore, etc.)
├── scripts/
│   ├── setup.sh                    — Phase 1 host setup, runs on Heimdall
│   ├── deploy.sh                   — Full deploy from workstation
│   ├── generate-secrets.sh         — One-time SOPS-encrypted secrets generator (workstation)
│   ├── onboard-periphery.sh        — Komodo Periphery onboarding (called by deploy.sh)
│   ├── seed-zones.sh               — Technitium .lab zone seeding (called by deploy.sh)
│   └── backup.sh                   — Nightly backup to Monolith
└── docs/
    ├── network-layout.md           — NIC roster, subnet usage
    ├── runbooks/
    │   ├── phase-1-host.md
    │   ├── phase-2-containers.md
    │   ├── phase-3-configuration.md
    │   ├── reconstruction.md
    │   ├── adding-a-route.md
    │   ├── trust-store-distribution.md
    │   └── fallback-haproxy-for-l4.md
    └── manual/
        ├── README.md (this manual's index)
        └── 01..07 (this manual)
```

## On-host paths

```
/opt/Homelab/                       — Git checkout
/opt/Homelab/Heimdall/.env          — Decrypted env vars (gitignored)
/opt/Homelab/Heimdall/secrets/technitium-admin-pw  — Decrypted password (gitignored)

/etc/komodo/
├── periphery.config.toml           — Periphery configuration (0640 root:root)
└── keys/
    ├── periphery.key               — Periphery private key (auto-generated)
    └── periphery.pub               — Periphery public key

/etc/systemd/system/periphery.service — Periphery systemd unit
/usr/local/bin/periphery             — Periphery binary

/etc/nftables.conf                   — Loaded by nftables.service
/etc/systemd/resolved.conf.d/no-stub.conf
/etc/systemd/journal-upload.conf.d/monolith.conf
/etc/systemd/journald.conf.d/limit.conf
/etc/docker/daemon.json
/etc/netplan/01-uplink.yaml
/etc/chrony/conf.d/heimdall.conf
/etc/apt/apt.conf.d/52heimdall-unattended

/var/lib/heimdall-setup/<step>.done  — setup.sh idempotence markers
/var/log/journal/                    — Persistent systemd journal
```

## Scripts — at-a-glance

| Script | Runs on | Invoked by | Idempotent? |
|---|---|---|---|
| [`setup.sh`](../../scripts/setup.sh) | Heimdall | Operator on first install + `--force <step>` re-runs | yes |
| [`deploy.sh`](../../scripts/deploy.sh) | Workstation | Operator routine | yes |
| [`generate-secrets.sh`](../../scripts/generate-secrets.sh) | Workstation | Operator once | refuses to overwrite |
| [`onboard-periphery.sh`](../../scripts/onboard-periphery.sh) | Heimdall | `deploy.sh` | yes (no-op if `onboarding_key` set) |
| [`seed-zones.sh`](../../scripts/seed-zones.sh) | Heimdall | `deploy.sh` | yes (additive only) |
| [`backup.sh`](../../scripts/backup.sh) | Heimdall | cron (`/etc/cron.daily`) | yes |

## Env vars in `.env` (decrypted from `env.sops.env`)

| Variable | Where used | Notes |
|---|---|---|
| `KOMODO_DATABASE_USERNAME` | Mongo init, Komodo Core | Default: `komodo` |
| `KOMODO_DATABASE_PASSWORD` | Mongo init, Komodo Core | 40 chars random |
| `KOMODO_INIT_ADMIN_USERNAME` | Komodo Core first-start admin seed | Default: `owner` |
| `KOMODO_INIT_ADMIN_PASSWORD` | Komodo Core first-start admin seed | 32 chars random; only seeds on first Mongo start |
| `KOMODO_JWT_SECRET` | Komodo Core (signs auth JWTs) | 64-char hex |
| `KOMODO_WEBHOOK_SECRET` | Komodo Core (validates webhook payloads) | 32-char hex |

Set in [`Heimdall/docker-compose.yml`](../../docker-compose.yml) `komodo-core.environment` block.

## CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| [`build-heimdall-caddy-img.yml`](../../../.github/workflows/build-heimdall-caddy-img.yml) | Push to `main` touching `Heimdall/caddy/image/**` | Builds custom Caddy image with `caddy-l4` plugin, pushes to GHCR as `homelab-heimdall-caddy:<tag>` |
| [`poll-caddy-l4-releases.yml`](../../../.github/workflows/poll-caddy-l4-releases.yml) | Weekly cron (Mondays 13:00 UTC) | Polls `mholt/caddy-l4` releases, opens PR if new tag |
| [`shellcheck.yml`](../../../.github/workflows/shellcheck.yml) | Push touching `**/*.sh` | Lints shell scripts with shellcheck |

Plus [`.github/dependabot.yml`](../../../.github/dependabot.yml) — weekly checks for docker base-image bumps in `Heimdall/caddy/image/Dockerfile` + github-actions versions.

## Common commands

### From the workstation

```bash
# Full deploy
bash Heimdall/scripts/deploy.sh

# Only re-ship secrets (no compose changes)
bash Heimdall/scripts/deploy.sh --no-deploy

# Only redeploy compose (secrets already current)
bash Heimdall/scripts/deploy.sh --no-secrets

# Dry-run
bash Heimdall/scripts/deploy.sh --dry-run

# Lookup secrets
sops --decrypt Heimdall/secrets/env.sops.env | grep KOMODO_INIT
sops --decrypt --input-type binary --output-type binary Heimdall/secrets/technitium-admin-pw.sops

# Edit a secret in $EDITOR
sops Heimdall/secrets/env.sops.env
```

### On Heimdall

```bash
# Stack overview
cd /opt/Homelab/Heimdall && docker compose ps

# Per-container logs
docker compose logs --tail=50 caddy           # or: technitium, komodo-core, mongo

# Restart a single service
docker compose restart caddy

# Full reset (preserves bind-mount state)
docker compose down && docker compose up -d

# Host services
systemctl status periphery docker nftables systemd-journal-upload chrony

# Re-apply a host config
sudo bash /opt/Homelab/Heimdall/scripts/setup.sh --force 04_nftables
sudo systemctl restart docker     # always after nftables flush

# Inspect Periphery state
sudo cat /etc/komodo/periphery.config.toml
sudo journalctl -u periphery -n 50

# Manual backup
bash /opt/Homelab/Heimdall/scripts/backup.sh
```

### Diagnostic one-liners

```bash
# DNS works?
dig @192.168.10.4 google.com           # external resolution
dig @192.168.10.4 komodo.lab           # internal .lab zone

# HTTPS chain works?
curl -fsS https://komodo.lab           # from a trusted client
curl -fsS --resolve komodo.lab:443:192.168.10.4 \
    --cacert <path-to-ca.crt> https://komodo.lab    # from anywhere

# Caddy upstream view
docker compose exec caddy curl -s http://localhost:2019/reverse_proxy/upstreams | jq

# Komodo Core API health
curl -fsS http://127.0.0.1:9120 | head -1     # on Heimdall

# Technitium login probe
curl -G --data-urlencode user=admin --data-urlencode pass=<pw> \
    http://192.168.10.4:5380/api/user/login | jq
```

## Runbook index

Imperative recipes. Linked from the manual chapters where relevant.

| Runbook | When to read |
|---|---|
| [`runbooks/phase-1-host.md`](../runbooks/phase-1-host.md) | First-time Ubuntu install + setup.sh |
| [`runbooks/phase-2-containers.md`](../runbooks/phase-2-containers.md) | Bringing up the Compose stack + onboarding |
| [`runbooks/phase-3-configuration.md`](../runbooks/phase-3-configuration.md) | Ongoing operations (records, routes) |
| [`runbooks/reconstruction.md`](../runbooks/reconstruction.md) | Disaster recovery |
| [`runbooks/adding-a-route.md`](../runbooks/adding-a-route.md) | Reference for the per-route Caddyfile pattern |
| [`runbooks/trust-store-distribution.md`](../runbooks/trust-store-distribution.md) | Per-OS CA root install |
| [`runbooks/fallback-haproxy-for-l4.md`](../runbooks/fallback-haproxy-for-l4.md) | If `caddy-l4` ever becomes unmaintainable |

## Design history

Not part of operational docs but useful when "why is it like this?" comes up:

| Doc | What's in it |
|---|---|
| [`docs/design/heimdall-planning.md`](../../../docs/design/heimdall-planning.md) | Planning decisions log (Pi Expert exclusion, IP choice, etc.) |
| [`docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/`](../../../docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/) | First pipeline run (initial design) |
| [`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/`](../../../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/) | Second pipeline run (finalize — Technitium, Komodo, no-MetalLB) |
| `…/FINAL.md` in each pipeline run | The approved plan + implementation punch list |

## Upstream documentation pointers

| Tool | Docs |
|---|---|
| Ubuntu 26.04 | <https://documentation.ubuntu.com/release-notes/26.04/> |
| Docker Engine | <https://docs.docker.com/engine/> |
| Docker Compose | <https://docs.docker.com/compose/> |
| nftables | <https://wiki.nftables.org> |
| Technitium DNS Server | <https://blog.technitium.com> + <https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md> |
| Caddy | <https://caddyserver.com/docs/> |
| caddy-l4 | <https://github.com/mholt/caddy-l4> |
| Komodo | <https://komo.do/docs/> |
| MongoDB 7.0 | <https://www.mongodb.com/docs/v7.0/> |
| SOPS | <https://github.com/getsops/sops> |
| age | <https://github.com/FiloSottile/age> |

## End of manual

You've read it. Bookmark the chapters that matter to your role:

- **Operator (daily):** [04 — Daily operations](04-operations.md), [06 — Troubleshooting](06-troubleshooting.md).
- **Engineer (changes):** [02 — Components](02-components.md), [03 — Deployment](03-deployment.md), [05 — Secrets](05-secrets.md).
- **Future-you (after a long break):** [01 — Architecture](01-architecture.md) to re-load context, then this Reference page.
- **A new admin onboarding for the first time:** [README](README.md) → [01](01-architecture.md) → [03](03-deployment.md). The rest is reference.
