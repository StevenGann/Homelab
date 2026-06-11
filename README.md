# Homelab IaC

Infrastructure as Code for a four-host homelab built around a Raspberry Pi
Kubernetes cluster. Every host's state is defined in this repository and
recoverable from scratch.

> **Status (2026-06): operational.** All 10 Hyperion Pi 5 workers run NixOS and
> are joined to the Heimdall k3s control plane (`Ready`, v1.34.5+k3s1). **GitOps
> is live** — FluxCD v2.8.8 (read-only, no token) reconciles `Hyperion/k8s/` and
> MetalLB v0.14.9 serves the `192.168.10.10–.99` LoadBalancer pool. Roughly 30
> services are deployed across the cluster (media automation, dashboards, AI
> agents, game-server management). The full per-service catalog with friendly
> `*.lab` URLs lives in [`docs/homelab-user-guide.md`](docs/homelab-user-guide.md).
>
> The NixOS imaging path is validated and in production (hardware-validated
> 2026-06-01). The legacy Debian/Packer path remains in-tree only as a fallback
> until the **2026-08-15 sunset gate**. Authoritative per-node runbook:
> [`Hyperion/docs/runbooks/turnkey-node-setup.md`](Hyperion/docs/runbooks/turnkey-node-setup.md).
>
> **Known architectural debt:** the k3s control plane runs in a bridge-networked
> container on Heimdall and is slated to move onto a dedicated Pi (breaks
> metrics-server and forces a placement workaround until then — see
> [ADR-0002](docs/design/adr-0002-containerized-control-plane-networking.md)).

---

## The Hosts

Each top-level directory maps to one physical host or cluster. The lab uses a
mythological naming scheme so a host's name no longer encodes its (changeable)
job.

| Host | Address | OS | Role |
|------|---------|----|----|
| **Hyperion** | `.101–.110` | NixOS | 10-node Raspberry Pi 5 k3s cluster. Runs the containerized workloads. |
| **Heimdall** | `.4` | Ubuntu Server 26.04 | x86 edge host: DNS, reverse proxy, SSO, container manager, k3s control plane, Pi-flashing services. |
| **Akasha** | `.247` | TrueNAS Scale | Pure-storage server (formerly "Monolith"). Serves NFS to the cluster; hosts the media library. |
| **Thoth** | `.144` | Ubuntu Server 26.04 | GPU compute host (formerly "Compute"): 2× RTX 6000 Ada. LLM inference, image gen, GPU transcoding. |

A fifth machine, **Epsilon** (`192.168.0.105`, a Pop!_OS workstation with an
RTX 4080), runs a Tdarr GPU transcode worker on the main home subnet. It is part
of the transcode fleet but is not otherwise managed from this repo.

### Heimdall (`192.168.10.4`)

The edge-services host. One x86 box that runs, or holds the IaC for:

- **Technitium DNS** — LAN forwarder, ad/malware filtering, and the authoritative `.lab` zone (every service has a `http://<app>.lab` name).
- **Caddy** — HTTPS reverse proxy + L4 router (`caddy-l4`), with an internal CA for `*.lab`.
- **Authentik** — single sign-on, in bring-up (see [`Heimdall/authentik/`](Heimdall/authentik/) and [`sso-bring-up.md`](Heimdall/docs/runbooks/sso-bring-up.md)).
- **cloudflared** — Cloudflare Tunnel IaC for selective public exposure (see [`Heimdall/cloudflared/`](Heimdall/cloudflared/)).
- **Komodo** — container-management UI (also manages Thoth via a Periphery agent).
- **k3s control plane** — `rancher/k3s:v1.34.5-k3s1` for the Hyperion cluster (`:6443`).
- **Hyperion flashing services** — image server (`:50011`), `ci-deploy` GitHub-release poller, and the journal-remote log sink (`:19532` / `:19531`).

Deploy from the workstation with `bash Heimdall/scripts/deploy.sh`. Full manual:
[`Heimdall/docs/manual/`](Heimdall/docs/manual/README.md).

### Hyperion (`192.168.10.101–.110`)

Ten Raspberry Pi 5s (`hyperion-alpha` … `hyperion-kappa`), each NixOS-on-NVMe,
joined as k3s workers to the Heimdall control plane. Workloads are reconciled by
FluxCD from [`Hyperion/k8s/`](Hyperion/k8s/README.md). The hardware build and the
software bring-up are chronicled in the
[Homelab blog series](https://stevengann.com). One command images a node end to
end; see [Provisioning](#provisioning-a-node), below.

### Akasha (`192.168.10.247`)

The TrueNAS Scale storage server, renamed from Monolith and converged on a
pure-storage role. It exports the media library and download/scratch space to the
cluster over NFS (`Downloads` / `TV-Shows` / `Movies`, `mapall=apps`/568) and
currently serves Jellyfin to the LAN. Tracked IaC is limited to the NFS export
runbook: [`Akasha/docs/runbooks/nfs-media-export.md`](Akasha/docs/runbooks/nfs-media-export.md).

### Thoth (`192.168.10.144`)

The GPU compute host: 2× RTX 6000 Ada (96 GB VRAM total), Ubuntu Server with a
Docker Compose stack managed via Komodo Periphery. It runs Ollama (LLMs incl.
`deepseek-r1:70b`), OpenWebUI, ComfyUI, a GPU-accelerated Jellyfin instance, and
a Tdarr transcode worker. Layout, ZFS pools, and the GPU/driver notes are in
[`Thoth/README.md`](Thoth/README.md); design rationale in
[`docs/design/thoth-plan.md`](docs/design/thoth-plan.md).

---

## Repository Structure

```
Homelab/
├── docs/
│   ├── todo.md                       # current operational state + next steps
│   ├── homelab-user-guide.md         # per-service catalog (friendly *.lab URLs)
│   ├── storage-audit-2026-06-05.md   # storage inventory
│   ├── design/                       # ADRs + planning docs
│   ├── agent-notes/                  # durable Pi/Linux/IaC knowledge
│   └── pipeline-runs/                # decision-record outputs (gitignored)
│
├── Hyperion/                         # 10-node Pi 5 k3s cluster
│   ├── nixos/                        # NixOS configs (validated, in production)
│   ├── k8s/                          # FluxCD GitOps manifests (~30 apps)
│   ├── setup-hyperion-node.sh        # turnkey one-command per-node install
│   ├── register-node-key.sh          # per-node SOPS age key registration
│   ├── inventory.yaml                # node name ↔ IP map
│   ├── configure-eeprom.sh           # sets Pi BOOT_ORDER (used by both paths)
│   ├── packer/  ansible/             # legacy Debian path (sunsets 2026-08-15)
│   └── docs/runbooks/                # Hyperion-specific runbooks
│
├── Heimdall/                         # x86 edge host (.4)
│   ├── caddy/        technitium/     # reverse proxy + DNS
│   ├── authentik/    cloudflared/    # SSO + Cloudflare tunnel
│   ├── komodo-data/                  # container-manager state
│   ├── hyperion/                     # Pi flashing services (image server, ci-deploy, journal sink)
│   ├── k3s-control-plane/            # rancher/k3s control plane
│   ├── scripts/                      # deploy.sh, seed-zones.sh, …
│   └── docs/manual/  docs/runbooks/
│
├── Thoth/                            # GPU compute host (.144)
│   ├── docker-compose.yml            # Ollama, OpenWebUI, ComfyUI, Jellyfin-GPU, Tdarr worker
│   ├── scripts/      hostconf/
│   └── (design: docs/design/thoth-plan.md)
│
└── Akasha/                           # TrueNAS storage host (.247)
    └── docs/runbooks/nfs-media-export.md
```

This pattern extends as IaC coverage grows — a new host gets its own top-level
directory.

---

## Network

Single VLAN `192.168.10.0/24`; the UCG (`.1`) is the gateway and DHCP server.
Node IPs are DHCP reservations by MAC, so power-on order does not equal IP order.

| Range | Purpose |
|-------|---------|
| `.1` | UCG gateway / DHCP server |
| `.4` | Heimdall (edge services + k3s control plane + Pi-flashing stack) |
| `.10–.99` | MetalLB LoadBalancer pool (~30 cluster services) |
| `.101–.110` | Hyperion Pi nodes (`alpha` → `kappa`, Greek-letter order) |
| `.144` | Thoth (GPU compute host) |
| `.180` | APC AP7900 PDU (switched, 8 outlets; Telnet CLI on `:23`) |
| `.247` | Akasha (TrueNAS storage) |

Heimdall ports: k3s API `:6443`, Flannel VXLAN `:8472/udp`, image server `:50011`,
journal-remote `:19532` (upload sink) and `:19531` (HTML browse), Technitium UI
`:5380`, Komodo `:9120`.

`*.lab` hostnames are served by Technitium and seeded declaratively from
`Heimdall/scripts/seed-zones.sh`; each cluster service also listens on port 80 so
the bare `http://<app>.lab` works. See the
[user guide](docs/homelab-user-guide.md) for the complete name/IP/port table.

---

## Services (GitOps)

Cluster workloads are declared under [`Hyperion/k8s/`](Hyperion/k8s/README.md)
and reconciled by FluxCD. A representative slice of what's deployed:

- **Media automation** — Prowlarr, Sonarr, Radarr, Lidarr, qBittorrent (ProtonVPN/WireGuard), plus Seerr, Cleanuparr, SuggestArr, Kapowarr, Youtarr, Trailarr, Listenarr, Musicseerr, boxarr, Sortarr, and a Tdarr server (with GPU workers on Thoth and Epsilon).
- **Streaming** — Navidrome; Jellyfin (served from Akasha, with a GPU instance under evaluation on Thoth); Jellystat.
- **Dashboards & monitoring** — Homarr (home page), Uptime-Kuma, Headlamp (k8s dashboard), Beszel, Speedtest-Tracker.
- **AI** — Hermes (self-hosted DeepSeek agent), Caldera (Obsidian-vault REST/MCP API); Ollama/OpenWebUI/ComfyUI on Thoth.
- **Other** — RomM (ROM manager), Pterodactyl (game-server panel), n8n (automation), MonolithBot (Discord bot).

The authoritative, always-current list (with URLs and what each is for) is the
[user guide](docs/homelab-user-guide.md).

---

## Provisioning a Node

The validated NixOS flow is one command per node. A node is imaged from a single
stock Raspberry Pi OS bootstrap SD (SSH enabled), driven entirely over SSH from
the workstation — the NVMe is a separate disk, so it is installed in place with
no re-flash dance.

```bash
cd Hyperion

# End-to-end: register keys → Nix on bootstrap → disko-install onto NVMe →
# set EEPROM boot order (0xf416) → reboot → verify the node reaches Ready.
# IP auto-resolves from inventory.yaml by name.
./setup-hyperion-node.sh --name hyperion-alpha

# Then pull the SD, move it to the next Pi, and repeat.
```

Full walkthrough and the Pi-specific gotchas (dead `kexec`, the memory cgroup,
the bootloader `mount`-on-PATH trap, EEPROM order) are in
[`Hyperion/docs/runbooks/turnkey-node-setup.md`](Hyperion/docs/runbooks/turnkey-node-setup.md).
Repo-wide operator conventions live in [`CLAUDE.md`](CLAUDE.md).

**Day-2 changes** (no re-flash): edit `Hyperion/nixos/`, then
`colmena apply --on hyperion-<greek>` (or `--on '@hyperion-*' --parallel 4`).
See [`deploy-via-colmena.md`](Hyperion/docs/runbooks/deploy-via-colmena.md).

**Replace a dead node:** [`replace-dead-node.md`](Hyperion/docs/runbooks/replace-dead-node.md).

> The legacy Debian/Packer path (`Hyperion/packer/`, `ansible/`, `reimage.sh`,
> `watch-flash.sh`, `publish-image.sh`) is paused and kept only as a fallback
> until the 2026-08-15 sunset gate. Don't use it for new nodes.

---

## Bringing Up the Cluster from Scratch

1. **Heimdall** — deploy the edge stack, the Pi-flashing services, and the **k3s control plane**: `bash Heimdall/scripts/deploy.sh` (see [`flashing-services.md`](Heimdall/docs/runbooks/flashing-services.md) and [`k3s-control-plane/README.md`](Heimdall/k3s-control-plane/README.md)).
2. **Workstation tooling** — install Nix, age, sops, and colmena (see [`tooling.md`](Hyperion/docs/runbooks/tooling.md)).
3. **Image the nodes** — `./setup-hyperion-node.sh --name hyperion-<greek>` for each Pi.
4. **Bootstrap GitOps** — `kubectl apply -k Hyperion/k8s/flux-system`; Flux then reconciles everything from `origin/main` (see [`Hyperion/k8s/README.md`](Hyperion/k8s/README.md)).

---

## Secrets

SOPS + age, with **per-node keys** on the NixOS path. Each Pi has its own age
private key, generated workstation-side by `register-node-key.sh`, stored
age-encrypted to the operator under `Hyperion/nixos/node-keys/` (committed), and
injected onto the node's NVMe at `/var/lib/sops-nix/key.txt` at install time —
never in git or the Nix store. Cluster Secrets are decrypted by Flux via the
`sops-age` Secret in `flux-system`.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>

# Add a node: generates its key, adds the pubkey to .sops.yaml, re-encrypts common.yaml
cd Hyperion && ./register-node-key.sh hyperion-<greek>
```

Flux-decrypted Secrets have a required encryption form (encrypt only
`data`/`stringData`, no comments) — see the SOPS section of
[`Hyperion/k8s/README.md`](Hyperion/k8s/README.md). Tooling cheat-sheet:
[`tooling.md`](Hyperion/docs/runbooks/tooling.md).

---

## Reproducibility Checklist

- [ ] Heimdall services (k3s control plane + flashing stack + edge services) restored from `bash Heimdall/scripts/deploy.sh` alone.
- [ ] Thoth GPU stack restored from `bash Thoth/scripts/deploy.sh` (host bootstrap via `Thoth/scripts/setup.sh`).
- [ ] Dead Hyperion node replaced per [`replace-dead-node.md`](Hyperion/docs/runbooks/replace-dead-node.md).
- [ ] Every cluster workload defined in `Hyperion/k8s/` and reconciled by Flux.
- [ ] All secrets SOPS-encrypted or stored outside the repo.

---

## Where the Knowledge Lives

- **[`docs/todo.md`](docs/todo.md)** — current operational state and the next steps.
- **[`CLAUDE.md`](CLAUDE.md)** — operator/agent conventions; the authoritative Hyperion architecture notes.
- **[`docs/design/`](docs/design/)** — ADRs and planning docs (e.g. ADR-0002 control-plane networking, ADR-0003 Longhorn deferred, the Thoth and \*arr-stack plans).
- **[`docs/agent-notes/`](docs/agent-notes/)** — durable Pi/Linux/IaC facts that survive each planning pipeline.
- **[`TEAM.md`](TEAM.md)** / **[`PIPELINES.md`](PIPELINES.md)** — the standing agent-team roster and the DEVELOPMENT/DEBUGGING orchestration used to design changes.
- Per-host docs: [`Heimdall/docs/manual/`](Heimdall/docs/manual/README.md), [`Thoth/README.md`](Thoth/README.md), [`Hyperion/docs/runbooks/`](Hyperion/docs/runbooks/), [`Akasha/docs/runbooks/`](Akasha/docs/runbooks/).
