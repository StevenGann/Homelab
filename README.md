# Homelab IaC

Infrastructure as Code for a four-host homelab built around a Raspberry Pi
Kubernetes cluster. Every host's state is defined in this repository and
recoverable from scratch.

> **Status (verified live 2026-09-05): operational.** All 10 Hyperion Pi 5
> workers run NixOS 25.11 and are joined to the Heimdall k3s control plane
> (`Ready`, v1.34.5+k3s1). **GitOps is live** — FluxCD reconciles `Hyperion/k8s/`
> (31 Kustomizations, all `Ready` at `main`) and MetalLB serves the
> `192.168.10.10–.99` LoadBalancer pool. **46 LoadBalancer services** are
> deployed across 31 namespaces (media automation, dashboards, AI agents,
> game-server management). The full per-service catalog with friendly `*.lab`
> URLs lives in [`docs/homelab-user-guide.md`](docs/homelab-user-guide.md).
>
> The NixOS imaging path is validated and in production (hardware-validated
> 2026-06-01). Authoritative per-node runbook:
> [`Hyperion/docs/runbooks/turnkey-node-setup.md`](Hyperion/docs/runbooks/turnkey-node-setup.md).
>
> **Open items as of 2026-09-05 (see [`docs/todo.md`](docs/todo.md)):**
>
> - **The 2026-08-15 Debian/Packer sunset gate lapsed unactioned.** The legacy
>   files were never moved to `Hyperion/retired/` and are still at their original
>   paths. Nothing on the NixOS path depends on them.
> - **Thoth (`.144`) is powered off** pending hardware changes; every service it
>   hosted (Ollama, OpenWebUI, ComfyUI, Jellyfin-GPU, Tdarr worker, Pterodactyl
>   Wings) is suspended until it returns.
> - **The Hyperion flashing stack on Heimdall is not running** (`Heimdall/hyperion/`
>   image server `:50011`, `ci-deploy`, `journal-remote` `:19532`/`:19531`). It is
>   still tracked in git but the compose project has not been brought up; node
>   `systemd-journal-upload` therefore has no sink.
> - **Authentik and cloudflared are tracked in the repo but are not deployed** —
>   no containers, and neither appears in `Heimdall/docker-compose.yml`.
> - **NixOS is still pinned to 25.11**, whose upstream support window has passed.
>   See [`nixos-channel-upgrade.md`](Hyperion/docs/runbooks/nixos-channel-upgrade.md).
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
| **Hyperion** | `.101–.110` | NixOS 25.11 | 10-node Raspberry Pi 5 k3s cluster. Runs the containerized workloads. |
| **Heimdall** | `.4` | Ubuntu Server 26.04 | x86 edge host: DNS, reverse proxy, container manager, k3s control plane. |
| **Akasha** | `.247` | TrueNAS Scale 25.04.2 | Pure-storage server (formerly "Monolith"). Serves NFS to the cluster; hosts the media library and the LAN Jellyfin. |
| **Thoth** | `.144` | Ubuntu Server 26.04 | GPU compute host (formerly "Compute"): 2× RTX 6000 Ada. **Currently powered off** pending hardware changes — its services are suspended. |

Two other machines appear in the lab but are not primary hosts:

- **Epsilon** (`192.168.0.105`, `WS-EPSILON`) — Ubuntu 26.04 desktop with an
  RTX 4080, on the **main home subnet**, not the homelab VLAN. It has historically
  run a Tdarr GPU transcode worker; that worker is **not running today** (no
  container runtime is installed on the host). Not managed from this repo.
- **owner-thinkpad** (`192.168.10.230`) — the operator workstation on the homelab
  VLAN. It holds the operator SSH key and the Nix/sops/colmena toolchain, and is
  the machine the `Hyperion/` provisioning scripts are meant to be run from.
  Heimdall's SSH is not reachable from the `192.168.0.0/24` subnet, so this host
  doubles as the jump box for edge-host work.

### Heimdall (`192.168.10.4`)

The edge-services host. One x86 box (single NIC in use: `enp12s0`, static
`192.168.10.4`).

**Running today** — the `heimdall` compose project (6 containers) plus the
`k3s-control-plane` project (1):

- **Pi-hole** — the **LAN-facing resolver**: it owns `0.0.0.0:53` and does the
  ad/malware filtering. It conditionally forwards the `.lab` zone to Technitium
  (`server=/lab/127.0.0.1#5353`, see [`Heimdall/pihole/etc-dnsmasq.d/`](Heimdall/pihole/etc-dnsmasq.d/)).
- **Technitium DNS** — **authoritative for the `.lab` zone only**, and reachable
  only from the host (`127.0.0.1:5353` for DNS, `127.0.0.1:5380` for the UI,
  published to the LAN as `technitium.lab` through Caddy). Records are seeded by
  [`Heimdall/scripts/seed-zones.sh`](Heimdall/scripts/seed-zones.sh).
- **Caddy** — HTTPS reverse proxy + L4 router (`caddy-l4`), host-networked, with
  an internal CA for `*.lab`. Also listens on `:7443` for `jf.stevengann.com`.
- **ddns-updater** — NoIP dynamic DNS for the public `*.ddns.net` names. This is
  the real public-DNS path. *(Currently reporting `unhealthy`.)*
- **Komodo** (+ **mongo**) — container-management UI, bound to `127.0.0.1:9120`
  and fronted by Caddy. A `periphery` agent also runs on the Heimdall host itself.
- **k3s control plane** — `rancher/k3s:v1.34.5-k3s1` for the Hyperion cluster
  (`:6443`, plus Flannel VXLAN `:8472/udp`).

**Tracked in the repo but NOT deployed** (verified 2026-09-05 — decide
retire-vs-restore before relying on any of it):

- **Authentik** — [`Heimdall/authentik/`](Heimdall/authentik/) and
  [`sso-bring-up.md`](Heimdall/docs/runbooks/sso-bring-up.md) exist, and the
  Caddyfile still serves `auth.lab`, but no container is running and Authentik is
  not in `Heimdall/docker-compose.yml`.
- **cloudflared** — [`Heimdall/cloudflared/`](Heimdall/cloudflared/) is tracked;
  nothing is running. Public exposure currently goes via ddns-updater + port
  forwarding instead.
- **Hyperion flashing services** — [`Heimdall/hyperion/`](Heimdall/hyperion/)
  defines the image server (`:50011`), the `ci-deploy` GitHub-release poller and
  the `journal-remote` log sink (`:19532` / `:19531`), but the compose project has
  never been started on this host. Consequence: the Pi workers' and Heimdall's own
  `systemd-journal-upload` units have no sink and restart continuously.

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

The TrueNAS Scale storage server (25.04.2), renamed from Monolith and converged
on a pure-storage role. Pools: `Media-Storage` (60 TB, 78% full), `App-Storage`,
`App-SSD`, `Jellyfin-SSD`, `boot-pool`. It also still runs one container app —
**Jellyfin** (`jellyfin/jellyfin:10.11.11`, NodePort `:30013`), which is the
lab's primary media server.

**As-built NFS model — one export per media category, not one shared `/data`.**
The cluster mounts eleven separate exports (`Media/Downloads`, `TV-Shows`,
`Movies`, `Comics`, `YouTube`, `Music`, `ROMs`, `Audiobooks`, `NextCloud`, and
the two `Application-Storage/immich-*` datasets), all
`sec=sys,rw,anonuid=568,anongid=568,all_squash` and exported to **both**
`192.168.10.0/24` and `192.168.0.0/24`. Three older wildcard exports
(`Application-Storage`, `Infra-Storage`, and the legacy
`Container-Data/k3s-control-plane/netboot-root`) also remain.

> ⚠️ Because downloads and media live in **separate exports**, they are separate
> filesystems inside the pods, so the \*arr apps cannot hardlink across them and
> fall back to copy-then-delete on import. This is a deliberate departure from the
> single-export design in
> [`Akasha/docs/runbooks/nfs-media-export.md`](Akasha/docs/runbooks/nfs-media-export.md),
> which documents the *planned* model rather than the as-built one. The PVs that
> match reality are in [`Hyperion/k8s/apps/media/00-storage/`](Hyperion/k8s/apps/media/00-storage/).

### Thoth (`192.168.10.144`)

The GPU compute host: 2× RTX 6000 Ada (96 GB VRAM total), Ubuntu Server with a
Docker Compose stack managed via Komodo Periphery. It runs Ollama (LLMs incl.
`deepseek-r1:70b`), OpenWebUI, ComfyUI, a GPU-accelerated Jellyfin instance, a
Tdarr transcode worker and Pterodactyl Wings. Layout, ZFS pools, and the
GPU/driver notes are in [`Thoth/README.md`](Thoth/README.md); design rationale in
[`docs/design/thoth-plan.md`](docs/design/thoth-plan.md).

> 🔌 **Thoth is powered off as of 2026-09-05** — no ICMP or SSH from either
> subnet — pending hardware changes. All of its services are suspended until it
> comes back. The `thoth.lab`, `ollama.lab`, `openwebui.lab` and `comfyui.lab`
> Caddy routes and DNS records still exist and will fail until then. The repo
> content under `Thoth/` describes the intended configuration for its return.

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
│   ├── caddy/  technitium/  pihole/  # reverse proxy + DNS (pihole is LAN-facing)
│   ├── authentik/    cloudflared/    # SSO + Cloudflare tunnel — TRACKED, NOT DEPLOYED
│   ├── komodo-data/                  # container-manager state
│   ├── hyperion/                     # Pi flashing services — TRACKED, NOT RUNNING
│   ├── k3s-control-plane/            # rancher/k3s control plane
│   ├── scripts/                      # deploy.sh, seed-zones.sh, …
│   └── docs/manual/  docs/runbooks/
│
├── Thoth/                            # GPU compute host (.144) — HOST POWERED OFF
│   ├── docker-compose.yml            # Ollama, OpenWebUI, ComfyUI, Jellyfin-GPU, Tdarr worker, Wings
│   ├── scripts/      hostconf/
│   └── (design: docs/design/thoth-plan.md)
│
├── Akasha/                           # TrueNAS storage host (.247)
│   └── docs/runbooks/nfs-media-export.md   # planned model; see README note on as-built
│
├── Sensors/                          # ESPHome DHT22 temperature nodes → MQTT → Home Assistant
│   └── Temperature/                  # 6 room nodes, SOPS-encrypted wifi/MQTT creds
│
└── provision_jmp_pi.py               # one-off provisioner for the JMP Pi (not part of a host dir)
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
| `.4` | Heimdall (edge services + k3s control plane) |
| `.10–.99` | MetalLB LoadBalancer pool (46 cluster services in use) |
| `.101–.110` | Hyperion Pi nodes (`alpha` → `kappa`, Greek-letter order) |
| `.144` | Thoth (GPU compute host) — **currently powered off** |
| `.147` | Home Assistant (`:8123`) — consumer of the Sensors MQTT feed; not IaC-tracked |
| `.180` | APC AP7900 PDU (switched, 8 outlets; Telnet CLI on `:23`) |
| `.201` | Synology NAS (`:5000`) — not IaC-tracked |
| `.230` | owner-thinkpad — operator workstation / jump box |
| `.231` | HDHomeRun tuner — not IaC-tracked |
| `.247` | Akasha (TrueNAS storage; Jellyfin NodePort `:30013`) |

Other addresses seen on the VLAN but not identified as managed hosts: `.179`,
`.191`, `.241`, `.254`.

**Heimdall ports, as actually bound:** k3s API `:6443` and Flannel VXLAN
`:8472/udp` (LAN); DNS `:53` (**Pi-hole**, LAN); HTTP `:80`, HTTPS `:443` and
`:7443` (Caddy, LAN); Pi-hole FTL `:8180` (LAN); SSH `:22` (LAN — **not routed
from `192.168.0.0/24`**). Localhost-only, published through Caddy: Technitium UI
`:5380` and DNS `:5353`, Komodo `:9120`, ddns-updater `:8053`, Caddy admin
`:2019`. The flashing-stack ports `:50011`, `:19532` and `:19531` are **not
listening** — that stack is not running.

`*.lab` hostnames resolve through **Pi-hole**, which forwards the `.lab` zone to
Technitium; records are seeded declaratively from
`Heimdall/scripts/seed-zones.sh`. Most cluster services also publish port 80 so
the bare `http://<app>.lab` works — the exceptions are `immich` (`:2283`),
`subwave` (`:7700–7702`), `orphanarr` (`:8790`), `agent-caldera` (`:8000`) and
`mosquitto` (`:1883`/`:9001`), which are reached on their native ports or through
a Caddy route. See the [user guide](docs/homelab-user-guide.md) for the complete
name/IP/port table.

---

## Services (GitOps)

Cluster workloads are declared under [`Hyperion/k8s/`](Hyperion/k8s/README.md)
and reconciled by FluxCD. A representative slice of what's deployed:

- **Media automation** — Prowlarr, Sonarr, Radarr, Lidarr, **three** qBittorrent+gluetun instances (`.58`/`.83`/`.84`, ProtonVPN WireGuard), plus Seerr, Cleanuparr, SuggestArr, Kapowarr, Youtarr, Trailarr, Listenarr, Musicseerr, boxarr, Sortarr, FlareSolverr, and a Tdarr server. *(Tdarr's GPU workers lived on Thoth and Epsilon and are both offline.)*
- **Streaming & libraries** — Navidrome (music), Komga (comics/manga), Subwave (AI DJ radio), Jellystat. Jellyfin itself runs on Akasha (`.247:30013`), not in the cluster.
- **Photos** — Immich (`.88:2283`, `immich.lab` via Caddy), library on Akasha NFS.
- **Dashboards & monitoring** — Homarr (home page), Uptime-Kuma, Headlamp (k8s dashboard), Beszel (+ a `beszel-agent` DaemonSet on every node), Speedtest-Tracker.
- **AI** — Guppi/Hermes (`.52`), Jeeves (`.80`), Cassandra (`.93`), the Alfred dashboard (`.11`), Caldera (`.70`) and agent-caldera (`.85`) Obsidian-vault APIs, plus Ignis (browser Obsidian, `.90`). *(Ollama/OpenWebUI/ComfyUI live on the offline Thoth.)*
- **Other** — RomM (ROM manager), NextCloud, ShareDirStat (disk-usage analyser), Pterodactyl (game-server panel — its Wings host is the offline Thoth), n8n (automation), Mosquitto MQTT + MQTT Explorer, MonolithBot (Discord bot), and ArchiSteamFarm.

Two live objects hold pool addresses without being useful:
`kube-system/traefik` (`.10` — k3s's bundled ingress, unused; the
`--disable=traefik,servicelb` cleanup is still outstanding) and `media/orphanarr`
(`.89` — hand-applied, scaled to 0 replicas, **not in git**).

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
> `watch-flash.sh`, `publish-image.sh`, `bootstrap.sh`, `flash-identity-usb.sh`,
> `flash-node.sh`) is dead. Its **2026-08-15 sunset gate passed without action** —
> the files were never moved into `Hyperion/retired/` and that directory does not
> exist. Nothing on the NixOS path depends on them, and the `Heimdall/hyperion/`
> stack that served their images is not running. Don't use any of it for new
> nodes; deleting it is an outstanding chore in [`docs/todo.md`](docs/todo.md).

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

> 🔑 **Where the operator key actually lives.** The private half of
> `age1u8tfm7s…` is on **owner-thinkpad (`192.168.10.230`)** at
> `~/.config/sops/age/keys.txt`, alongside the Flux key
> (`hyperion-flux.txt`). Verified working 2026-09-05. It was believed lost after a
> 2026-07-06 workstation migration — it wasn't, it just never left the old
> machine. `docs/sops-secret-inventory.md` and
> [`key-backup-and-recovery.md`](docs/runbooks/key-backup-and-recovery.md) were
> written on the lost-key premise and now carry correction banners; **do not run
> their re-key procedure.**
>
> ⚠️ **It exists on exactly one machine with no off-site backup** — one disk
> failure from being genuinely lost. `sops`/`age`/`colmena` are also installed
> only there, so it is the only host that can author a secret. Backing it up is
> an open item in [`docs/todo.md`](docs/todo.md).
>
> Two files are also committed as **plaintext**, not SOPS:
> `Hyperion/k8s/apps/nextcloud/mariadb-secret.yaml` and
> `Hyperion/k8s/infrastructure/mosquitto/secret.yaml`.

---

## Reproducibility Checklist

Aspirations, with the 2026-09-05 verification result against each:

- [ ] **Heimdall services restored from `bash Heimdall/scripts/deploy.sh` alone.** ⚠️ Not true today: the script brings up Authentik, which is not part of the running stack, and the `Heimdall/hyperion/` flashing stack it also ships has never been started here.
- [x] **Hyperion nodes rebuildable from `Hyperion/nixos/`.** Live matches git 1:1; the flake is pinned and per-node age keys are committed.
- [ ] **Thoth GPU stack restored from `bash Thoth/scripts/deploy.sh`** (host bootstrap via `Thoth/scripts/setup.sh`). Unverifiable while the host is powered off.
- [ ] Dead Hyperion node replaced per [`replace-dead-node.md`](Hyperion/docs/runbooks/replace-dead-node.md).
- [ ] **Every cluster workload defined in `Hyperion/k8s/` and reconciled by Flux.** ⚠️ Two exceptions: `media/orphanarr` and `hermes/alfred-dashboard` are live with no git source.
- [ ] **All secrets SOPS-encrypted or stored outside the repo.** ⚠️ Two are committed in plaintext. The operator key needed to re-encrypt them exists (on owner-thinkpad) but has no off-site backup.
- [ ] **Persistent data recoverable.** ❌ No backup exists for any `local-path` PVC, and Akasha has no snapshot or replication schedule.

---

## Where the Knowledge Lives

- **[`docs/todo.md`](docs/todo.md)** — current operational state and the next steps.
- **[`CLAUDE.md`](CLAUDE.md)** — operator/agent conventions; the authoritative Hyperion architecture notes.
- **[`docs/design/`](docs/design/)** — ADRs and planning docs (e.g. ADR-0002 control-plane networking, ADR-0003 Longhorn deferred, the Thoth and \*arr-stack plans).
- **[`docs/agent-notes/`](docs/agent-notes/)** — durable Pi/Linux/IaC facts that survive each planning pipeline.
- **[`docs/runbooks/`](docs/runbooks/)** — repo-wide runbooks: [disaster recovery](docs/runbooks/disaster-recovery.md), [key backup & recovery](docs/runbooks/key-backup-and-recovery.md), and [client can't reach homelab services across subnets](docs/runbooks/troubleshoot-client-lan-connectivity.md).
- **[`TEAM.md`](TEAM.md)** / **[`PIPELINES.md`](PIPELINES.md)** — the standing agent-team roster and the DEVELOPMENT/DEBUGGING orchestration used to design changes.
- Per-host docs: [`Heimdall/docs/manual/`](Heimdall/docs/manual/README.md), [`Thoth/README.md`](Thoth/README.md), [`Hyperion/docs/runbooks/`](Hyperion/docs/runbooks/), [`Akasha/docs/runbooks/`](Akasha/docs/runbooks/).
