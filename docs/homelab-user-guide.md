# Homelab — User Guide

*A hand-off reference for trusted users with admin access. Last updated 2026-06-07.*

All services below run on the home network (`192.168.10.0/24`) — open the links
while connected to the LAN (or through the remote-access method the administrator
gave you). They are **not** exposed to the public internet.

**Credentials:** ask the administrator. Most apps have their own login (often set
on first visit); a few share the standard internal-admin password. Treat every
link here as admin access — please don't change settings you don't understand.

> 🔖 **Friendly names (`*.lab`):** every service now has a memorable name like
> `http://seerr.lab` in addition to its raw IP. These only work when your device
> uses the homelab DNS server (Heimdall, `192.168.10.4`) — most devices on the
> network do automatically. **If a `.lab` link doesn't load, use the Direct
> (IP:port) link in the next column** and check with an admin that your DNS is
> pointed at `192.168.10.4`. All `.lab` links are plain `http://` (no HTTPS yet).

> 💡 **Start here:** **[http://homarr.lab](http://homarr.lab)** (or
> [192.168.10.53:7575](http://192.168.10.53:7575)) — the homelab home page; it
> links out to everything below.

---

## 🎬 Watch & Listen

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Jellyfin** | [jellyfin.lab:30013](http://jellyfin.lab:30013) | [192.168.10.247:30013](http://192.168.10.247:30013) | The main media server (Akasha NodePort) — stream Movies, TV, and Music. This is what most people use day-to-day. |
| **Jellyfin (Thoth)** | — | [192.168.10.144:8096](http://192.168.10.144:8096) | Parallel GPU-accelerated Jellyfin instance on the GPU server. Dual RTX 6000 Ada for NVENC hardware transcoding. Currently in evaluation alongside the primary instance. |
| **Navidrome** | [navidrome.lab](http://navidrome.lab) | [192.168.10.66:4533](http://192.168.10.66:4533) | Dedicated music streaming (Subsonic-compatible — works with apps like DSub, play:Sub, Symfonium). |
| **Seerr** | [seerr.lab](http://seerr.lab) | [192.168.10.54:5055](http://192.168.10.54:5055) | **Request** new movies & shows. Search for something, click request, and it gets downloaded and added automatically. The friendliest way to add content. |
| **Musicseerr** | [musicseerr.lab](http://musicseerr.lab) | [192.168.10.74](http://192.168.10.74) | Music request & discovery app — like Seerr but for music. Search the MusicBrainz catalogue, request albums through Lidarr. |

---

## 📺 Media Automation (the "*arr" apps)

These run the library behind the scenes — request something in **Seerr** and you
usually never need to touch these. Admin/power-user territory.

| App | Link | Direct (IP:port) | What it manages |
|---|---|---|---|
| **Sonarr** | [sonarr.lab](http://sonarr.lab) | [192.168.10.56:8989](http://192.168.10.56:8989) | TV shows — searches, downloads, renames, organizes episodes. |
| **Radarr** | [radarr.lab](http://radarr.lab) | [192.168.10.57:7878](http://192.168.10.57:7878) | Movies — same idea as Sonarr. |
| **Lidarr** | [lidarr.lab](http://lidarr.lab) | [192.168.10.65:8686](http://192.168.10.65:8686) | Music albums/artists. |
| **Kapowarr** | [kapowarr.lab](http://kapowarr.lab) | [192.168.10.60:5656](http://192.168.10.60:5656) | Comics & manga. |
| **Youtarr** | [youtarr.lab](http://youtarr.lab) | [192.168.10.61:3087](http://192.168.10.61:3087) | Archives YouTube channels/videos into the library. |
| **Prowlarr** | [prowlarr.lab](http://prowlarr.lab) | [192.168.10.55:9696](http://192.168.10.55:9696) | Indexer manager — the search sources the *arr apps use. Central config. |
| **Trailarr** | [trailarr.lab](http://trailarr.lab) | [192.168.10.63:7889](http://192.168.10.63:7889) | Downloads trailers for the movie/TV library. |
| **Tdarr** | [tdarr.lab](http://tdarr.lab) | [192.168.10.62:8266](http://192.168.10.62:8266) | Transcoding & library health (re-encodes files; GPU worker nodes on Thoth [2× RTX 6000 Ada] and Epsilon [RTX 4080]). |
| **Listenarr** | [listenarr.lab](http://listenarr.lab) | [192.168.10.73](http://192.168.10.73) | Audiobook manager — like Sonarr but for audiobooks. Searches, downloads, and organizes your audiobook library. |

---

## ⬇️ Downloads

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **qBittorrent** | [qbittorrent.lab](http://qbittorrent.lab) | [192.168.10.58:8085](http://192.168.10.58:8085) | The download client — routes through ProtonVPN (WireGuard, San Jose CA) with NAT-PMP port forwarding and kill-switch. The *arr apps drive it automatically — you rarely need to open it. |
| **Cleanuparr** | [cleanuparr.lab](http://cleanuparr.lab) | [192.168.10.59:11011](http://192.168.10.59:11011) | Housekeeping — clears stalled/failed downloads automatically. |
| **SuggestArr** | [suggestarr.lab](http://suggestarr.lab) | [192.168.10.64:5000](http://192.168.10.64:5000) | Auto-suggests content based on what's been watched and feeds it to Seerr. |
| **boxarr** | [boxarr.lab](http://boxarr.lab) | [192.168.10.75](http://192.168.10.75) | Box office tracker — monitors weekly box office charts and auto-adds trending movies to Radarr. |

---

## 📊 Dashboards & Monitoring

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Homarr** | [homarr.lab](http://homarr.lab) | [192.168.10.53:7575](http://192.168.10.53:7575) | The homelab home page — quick links + at-a-glance status. **Bookmark this one.** |
| **Uptime Kuma** | [uptime.lab](http://uptime.lab) | [192.168.10.51](http://192.168.10.51) | Service status / uptime monitoring — is everything healthy? |
| **Headlamp** | [headlamp.lab](http://headlamp.lab) | [192.168.10.50](http://192.168.10.50) | Kubernetes dashboard — the cluster everything runs on (deep admin). |
| **Beszel** | [beszel.lab](http://beszel.lab) | [192.168.10.68:8090](http://192.168.10.68:8090) | Lightweight server/host monitoring (CPU, memory, disk, network). |
| **Speedtest Tracker** | [speedtest.lab](http://speedtest.lab) | [192.168.10.67](http://192.168.10.67) | Tracks internet speed over time (scheduled speedtests + history graphs). |
| **Jellystat** | [jellystat.lab](http://jellystat.lab) | [192.168.10.76](http://192.168.10.76) | Jellyfin statistics — view watch history, user activity, library stats. |
| **Sortarr** | [sortarr.lab](http://sortarr.lab) | [192.168.10.77](http://192.168.10.77) | Media library insights — analyse libraries across Sonarr, Radarr, Jellyfin, Plex. Read-only analytics tool. |
| **RomM** | [romm.lab](http://romm.lab) | [192.168.10.78:8080](http://192.168.10.78:8080) | ROM manager — organise and play retro game ROMs. IGDB metadata integration for box art, screenshots, and game info. Library on Akasha NFS. |

---

## 🤖 AI

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Guppi** (Hermes) | [guppi.lab](http://guppi.lab) | [192.168.10.52](http://192.168.10.52) | Self-hosted AI agent (DeepSeek-backed). The primary agent — interacts via Discord DM. **Login required** (HTTP basic auth — ask the admin). Formerly named Hermes; renamed June 2026. |
| **Jeeves** | [jeeves.lab](http://jeeves.lab) | [192.168.10.80](http://192.168.10.80) | Second DeepSeek agent instance. Independent deployment — Discord not yet connected. **Login required** (same basic auth as Guppi). |
| **Caldera** | [caldera.lab](http://caldera.lab) | [192.168.10.70:8000](http://192.168.10.70:8000) | REST/MCP API that exposes the Obsidian vault to AI agents (read/write notes, search). Not a click-and-use site — needs a **Bearer token** (ask the admin); interactive API docs at `/docs`. |
| **Ollama** | [ollama.lab](http://ollama.lab) | [192.168.10.144:11434](http://192.168.10.144:11434) | Local LLM inference on the GPU server (Thoth, 2× RTX 6000 Ada). An API for agents/apps (OpenAI-compatible at `/v1`) — pair it with a chat UI. No login; internal only. |
| **OpenWebUI** | [openwebui.lab](http://openwebui.lab) | [192.168.10.144:3000](http://192.168.10.144:3000) | **The friendly chat front-end for Ollama** (ChatGPT-style). The easy way to talk to the local models. **Own login** — the first account created becomes the admin. |
| **ComfyUI** | [comfyui.lab](http://comfyui.lab) | [192.168.10.144:8188](http://192.168.10.144:8188) | AI image generation (Stable Diffusion, node-based) on the GPU. No login — internal only. Needs models added before it can generate. |

---

## 🎮 Game Servers

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Pterodactyl** | [pterodactyl.lab](http://pterodactyl.lab) | [192.168.10.69](http://192.168.10.69) | Game-server management panel. Create/manage servers (Minecraft, Rust, etc.). Game servers themselves run on dedicated "Wings" hosts (added separately). **Login required.** |

## 🛠️ Infrastructure (advanced — platform admins only)

| System | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **TrueNAS (Akasha)** | [akasha.lab](https://akasha.lab) | [192.168.10.247](https://192.168.10.247) | The storage server — all media + app data lives here. FTP access enabled on port 21 (`truenas_admin` with admin password) for direct file management; NFS exports accessible from both homelab VLAN (.10.x) and main subnet (.0.x). |
| **Thoth** (GPU compute) | [thoth.lab](http://thoth.lab) | [192.168.10.144](http://192.168.10.144) | GPU server (2× RTX 6000 Ada, 96 GB VRAM). Runs **Ollama** (LLMs: deepseek-r1:70b, llama3.2:1b), **OpenWebUI** (chat), **ComfyUI** (image gen), **Jellyfin** (GPU-accelerated instance at :8096), and the **Tdarr** transcode worker node. Container host via Docker Compose — manage it via **Komodo** (`komodo.lab`). |
| **Epsilon** (workstation) | — | `192.168.0.105` | Sydney's Pop!_OS desktop (RTX 4080, 16GB VRAM). Runs a **Tdarr** GPU transcode worker node (Docker Compose, `epsilon-gpu`). NFS-mounted media from Akasha. On the main home subnet — not the homelab VLAN. |
| **DNS / Container manager / Reverse proxy** | on **[heimdall.lab](http://heimdall.lab)** (`192.168.10.4`) | `192.168.10.4` | Technitium (DNS + ad-blocking), Komodo (containers — `komodo.lab` via the reverse proxy), and Caddy (reverse proxy). **Ask the administrator for the admin URLs.** |
| **APC PDU** | — (Telnet CLI) | `192.168.10.180:23` | Switched Rack PDU (APC AP7900, 8 outlets). Controls power to Monolith, Compute, Synology and 5 other devices. Admin access via Telnet CLI — not a web service. **No HTTPS/SSH** (non-B hardware). |

---

## How it fits together (the 30-second version)

```
You request a movie in  Seerr  ─▶  Radarr/Sonarr/Lidarr  ─▶  Prowlarr (find it)
                                          │
                                          ▼
                                   qBittorrent (download, via VPN)
                                          │
                                          ▼
                        organized into the library on TrueNAS (Akasha)
                                          │
                                          ▼
                          Jellyfin / Navidrome  ─▶  you watch / listen
```

Everything runs on **Hyperion**, a 10-node
Raspberry Pi 5 Kubernetes cluster — including Jellyfin since the migration from
Akasha in June 2026. The storage (TrueNAS / Akasha) provides NFS volumes to the
cluster. If a link is down, check **Uptime Kuma** or
ping a platform admin.

---

## Naming reference (for admins)

The `*.lab` names are served by Technitium DNS on Heimdall (`192.168.10.4`),
seeded declaratively from `Heimdall/scripts/seed-zones.sh`. Each app's
LoadBalancer also listens on **port 80** (in addition to its native port) so the
bare `http://<app>.lab` works without a port suffix — defined per-service in
`Hyperion/k8s/apps/**/service.yaml`. The native `IP:port` links remain valid and
are also what the apps use to talk to each other internally.
