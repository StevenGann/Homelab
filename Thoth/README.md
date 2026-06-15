# Thoth — GPU compute host

`192.168.10.144` · Ubuntu Server 26.04 · 2× RTX 6000 Ada (48 GB each) · 16 cores / 123 GB RAM.
Container host for GPU workloads, run **consistent with Heimdall's pattern**
(Compose + `scripts/setup.sh` host bootstrap). Plan/rationale:
[`docs/design/thoth-plan.md`](../docs/design/thoth-plan.md).

## Layout

| | |
|---|---|
| `docker-compose.yml` | the stack — **Ollama, OpenWebUI, ComfyUI, Tdarr worker, Komodo Periphery, Wings (Minecraft — pinned 1.11.x), BlueMap** (all live). Jellyfin was a GPU-transcode test, decommissioned 2026-06-15. |
| `scripts/setup.sh` | host bootstrap (Docker, NVIDIA driver+toolkit, nfs-common, daemon.json; `--provision-storage` for the ZFS pools). |
| `hostconf/docker-daemon.json` | journald logging + live-restore (nvidia runtime merged in by `nvidia-ctk`). |
| `.sops.yaml` / `secrets/` | same homelab age key. `env.sops.env` (OpenWebUI secret); `wings-config.sops.yaml` (Wings node config — token + allowed_origins, seeded to `/etc/pterodactyl/config.yml` if absent). |

State root `/opt/Homelab/Thoth/` (config). Bulk **data on ZFS** (too big for boot):

| Pool / disk | Backing | Mount | Use |
|---|---|---|---|
| `tank` (raidz1) | 4× 1 TB HDD | `/tank` | models (`tank/ollama`), bulk |
| `fast` | Samsung 960 GB SSD | `/fast` | game servers (Wings) |
| Intel 240 GB SSD | ext4 | `/var/lib/docker` | Docker data-root (off boot) |
| boot | Samsung 1.9 TB NVMe | `/` | OS only |

## GPU (critical)

Host driver **595.71.05 / CUDA 13.2** (open-595-server). NVIDIA Container Toolkit
wires the `nvidia` runtime into Docker; containers request GPUs per-service:

```yaml
deploy: { resources: { reservations: { devices: [ { driver: nvidia, count: all, capabilities: [gpu] } ] } } }
```

`count: all` = both GPUs (Ollama and the future Tdarr worker share them — separate
CUDA vs NVENC engines). Smoke test: `docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi`.

## Operate

```bash
cd /opt/Homelab/Thoth && docker compose up -d         # bring up / apply changes
docker compose logs -f ollama
docker exec thoth-ollama-1 ollama pull <model>        # models land on /tank/ollama
```

- **Ollama** — `http://ollama.lab` (Heimdall Caddy → `192.168.10.144:11434`) or direct on `:11434`.
- **OpenWebUI** — `http://openwebui.lab` (or `:3000`); chat UI for Ollama, own login (first user = admin).
- **ComfyUI** — `http://comfyui.lab` (or `:8188`); image gen on GPU, models under `/tank/comfyui` (start empty). No native auth — LAN/VPN only.
- **Komodo Periphery** — `:8120`; manages Thoth's containers from `komodo.lab`. Onboard from the panel (v2 onboarding-key handshake; see the runbook).
- **Tdarr worker** — enable once Akasha exports the shared transcode cache + media (plan §3b).
- **Wings** — Pterodactyl game-server daemon for the panel on `192.168.10.69`. Console websocket is on `:8080` (browser connects **directly**), SFTP `:2022`. **Pinned to 1.11.x to match Panel 1.11.x** — Wings 1.12+ breaks the console with "jwt: missing connect permission". `config.yml` `allowed_origins` must list every hostname the panel is loaded as (e.g. `http://pterodactyl.lab`).
- **BlueMap** — `:8100`; read-only 3D web map of the Minecraft world.

Deploy/update the stack: `Thoth/scripts/deploy.sh` (ships SOPS secrets + compose, then `docker compose up -d`).
