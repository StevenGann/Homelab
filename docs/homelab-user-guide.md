# Homelab — User Guide

*A hand-off reference for trusted users with admin access. Last verified against
the live lab 2026-09-05.*

> 🔌 **Thoth, the GPU server, is powered off** pending hardware changes. Anything
> listed below at `192.168.10.144` — the GPU Jellyfin, Ollama, OpenWebUI, ComfyUI —
> **will not load** until it comes back. Everything else in this guide is up.

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
>
> ⚠️ **If a whole device can't reach *anything* homelab** — no `.lab` names, no
> services even by raw IP — but its own subnet and the internet work fine, the
> usual culprit is a **full-tunnel VPN** on that device (e.g. PIA) swallowing
> cross-subnet traffic. Add the home subnets as split-tunnel/bypass rules. Full
> diagnosis: [`troubleshoot-client-lan-connectivity.md`](runbooks/troubleshoot-client-lan-connectivity.md).

> 💡 **Start here:** **[http://homarr.lab](http://homarr.lab)** (or
> [192.168.10.53:7575](http://192.168.10.53:7575)) — the homelab home page; it
> links out to everything below.

---

## 🎬 Watch & Listen

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Jellyfin** | [jellyfin.lab:30013](http://jellyfin.lab:30013) | [192.168.10.247:30013](http://192.168.10.247:30013) | The main media server (Akasha NodePort) — stream Movies, TV, and Music. This is what most people use day-to-day. |
| **Jellyfin (Thoth)** | — | `192.168.10.144:8096` | ⚠️ **Offline.** Parallel GPU-accelerated Jellyfin on the GPU server (dual RTX 6000 Ada, NVENC). Returns when Thoth does. |
| **Navidrome** | [navidrome.lab](http://navidrome.lab) | [192.168.10.66:4533](http://192.168.10.66:4533) | Dedicated music streaming (Subsonic-compatible — works with apps like DSub, play:Sub, Symfonium). |
| **Seerr** | [seerr.lab](http://seerr.lab) | [192.168.10.54:5055](http://192.168.10.54:5055) | **Request** new movies & shows. Search for something, click request, and it gets downloaded and added automatically. The friendliest way to add content. |
| **Musicseerr** | [musicseerr.lab](http://musicseerr.lab) | [192.168.10.74](http://192.168.10.74) | Music request & discovery app — like Seerr but for music. Search the MusicBrainz catalogue, request albums through Lidarr. |
| **Komga** | [komga.lab](http://komga.lab) | [192.168.10.82:25600](http://192.168.10.82:25600) | Comic & manga server — read CBZ/CBR/PDF in the browser or via any OPDS reader. |
| **Subwave** | [subwave.lab](https://subwave.lab) | [192.168.10.91:7700](http://192.168.10.91:7700) | AI DJ internet radio — a continuously-programmed station with generated between-track segments. Stream at `/stream.mp3`. |

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
| **Listenarr** | [listenarr.lab](http://listenarr.lab) | [192.168.10.73](http://192.168.10.73) | Audiobook manager — like Sonarr but for audiobooks. Searches, downloads, and organizes your audiobook library. |

---

## ⬇️ Downloads

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **qBittorrent** | [qbittorrent.lab](http://qbittorrent.lab) | [192.168.10.58:8085](http://192.168.10.58:8085) | The download client — routes through ProtonVPN (WireGuard, San Jose CA) with NAT-PMP port forwarding and kill-switch. The *arr apps drive it automatically — you rarely need to open it. |
| **qBittorrent B** | [qbittorrent-b.lab](http://qbittorrent-b.lab) | [192.168.10.83:8085](http://192.168.10.83:8085) | Second download client + gluetun instance (Seattle VPN exit). |
| **qBittorrent C** | [qbittorrent-c.lab](http://qbittorrent-c.lab) | [192.168.10.84:8085](http://192.168.10.84:8085) | Third download client + gluetun instance (Los Angeles VPN exit). |
| **Cleanuparr** | [cleanuparr.lab](http://cleanuparr.lab) | [192.168.10.59:11011](http://192.168.10.59:11011) | Housekeeping — clears stalled/failed downloads automatically. |
| **SuggestArr** | [suggestarr.lab](http://suggestarr.lab) | [192.168.10.64:5000](http://192.168.10.64:5000) | Auto-suggests content based on what's been watched and feeds it to Seerr. |
| **boxarr** | [boxarr.lab](http://boxarr.lab) | [192.168.10.75](http://192.168.10.75) | Box office tracker — monitors weekly box office charts and auto-adds trending movies to Radarr. |

---

## 🖼 Photo & Video Management

| App | Link | Direct (IP:port) | What it is for |
|---|---|---|---|
| **Immich** | [immich.lab](https://immich.lab) | [192.168.10.88:2283](http://192.168.10.88:2283) | Self-hosted Google Photos alternative — automatic phone backup, face recognition, albums, search. Photo library stored on Akasha (TrueNAS NFS). |
| **NextCloud** | [nextcloud.lab](http://nextcloud.lab) | [192.168.10.87](http://192.168.10.87) | Files, calendar and contacts. Data on Akasha NFS. **Own login.** |
| **ShareDirStat** | [sharedirstat.lab](https://sharedirstat.lab) | [192.168.10.92](http://192.168.10.92) | Disk-usage analyser for the Akasha shares — find what's eating the 60 TB. Deletion is **enabled**, so tread carefully. |

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
| **Alfred** | *(name not wired)* | [192.168.10.11](http://192.168.10.11) | Family-facing chat UI in front of the Guppi/Hermes agent API. ⚠️ The `alfred.lab` reverse-proxy route exists but **has no DNS record**, so the friendly name does not resolve — use the IP. |
| **Caldera** | [caldera.lab](http://caldera.lab) | [192.168.10.70:8000](http://192.168.10.70:8000) | REST/MCP API that exposes the Obsidian vault to AI agents (read/write notes, search). Not a click-and-use site — needs a **Bearer token** (ask the admin); interactive API docs at `/docs`. |
| **Cassandra** | — | [192.168.10.93](http://192.168.10.93) | Third agent instance (Sigurd's assistant), Discord-connected. **Login required** (basic auth). No `.lab` name yet. |
| **Ignis** | [ignis.lab](https://ignis.lab) | [192.168.10.90:8080](http://192.168.10.90:8080) | Obsidian in the browser, serving the real vault — **full read/write**. **Login required** (basic auth at the proxy; Ignis itself has none). |
| **agent-caldera** | [agent-caldera.lab](http://agent-caldera.lab) | [192.168.10.85:8000](http://192.168.10.85:8000) | Second Caldera instance holding the agents' shared-knowledge vault. Bearer token, same as Caldera. |
| **Ollama** | [ollama.lab](http://ollama.lab) | `192.168.10.144:11434` | ⚠️ **Offline with Thoth.** Local LLM inference on the GPU server (2× RTX 6000 Ada); OpenAI-compatible API at `/v1`. |
| **OpenWebUI** | [openwebui.lab](http://openwebui.lab) | `192.168.10.144:3000` | ⚠️ **Offline with Thoth.** The friendly chat front-end for Ollama (ChatGPT-style). **Own login.** |
| **ComfyUI** | [comfyui.lab](http://comfyui.lab) | `192.168.10.144:8188` | ⚠️ **Offline with Thoth.** AI image generation (Stable Diffusion, node-based) on the GPU. Needs models added before it can generate. |

---

## 🎮 Game Servers

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **Pterodactyl** | [pterodactyl.lab](http://pterodactyl.lab) | [192.168.10.69](http://192.168.10.69) | Game-server management panel. The panel is up, but its only "Wings" host is Thoth — so ⚠️ **no game server can start** while Thoth is off. **Login required.** |
| **ArchiSteamFarm** | [asf.lab:1242](http://asf.lab:1242) | [192.168.10.86:1242](http://192.168.10.86:1242) | Steam trading-card farmer — idles your Steam library to collect cards automatically. **Login required** (IPC password — ask the admin). Migrated from a workstation into the cluster July 2026. |

## 🔧 Automation & Messaging

| App | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **n8n** | [n8n.lab](http://n8n.lab) | [192.168.10.71:5678](http://192.168.10.71:5678) | Visual workflow automation — wire services together on triggers/schedules. **Own login** (first visitor creates the admin account). |
| **Mosquitto (MQTT)** | [mqtt.lab](http://mqtt.lab) | `192.168.10.72:1883` | The MQTT broker. Not a website — the ESPHome room-temperature sensors publish here and Home Assistant subscribes. |
| **MQTT Explorer** | [mqttexplorer.lab](http://mqttexplorer.lab) | [192.168.10.81](http://192.168.10.81) | Web UI for browsing what's flowing through the MQTT broker. Handy for debugging the sensors. |
| **MonolithBot** | [monolithbot.lab](http://monolithbot.lab) | [192.168.10.79](http://192.168.10.79) | Discord bot admin UI. |

---

## 🛠️ Infrastructure (advanced — platform admins only)

| System | Link | Direct (IP:port) | What it's for |
|---|---|---|---|
| **TrueNAS (Akasha)** | [akasha.lab](https://akasha.lab) | [192.168.10.247](https://192.168.10.247) | The storage server — all media + app data lives here. FTP access enabled on port 21 (`truenas_admin` with admin password) for direct file management; NFS exports accessible from both homelab VLAN (.10.x) and main subnet (.0.x). |
| **Thoth** (GPU compute) | — | `192.168.10.144` | ⚠️ **POWERED OFF** pending hardware changes. GPU server (2× RTX 6000 Ada, 96 GB VRAM) — normally runs **Ollama**, **OpenWebUI**, **ComfyUI**, a GPU **Jellyfin** at `:8096`, and Pterodactyl **Wings**. All suspended until it returns. |
| **Epsilon** (workstation) | — | `192.168.0.105` | Desktop workstation `WS-EPSILON` (Ubuntu 26.04, RTX 4080 16 GB). Formerly ran a **Tdarr** GPU worker — **Tdarr has been fully retired**. On the main home subnet — not the homelab VLAN. |
| **Home Assistant** | [homeassistant.lab:8123](http://homeassistant.lab:8123) | [192.168.10.147:8123](http://192.168.10.147:8123) | Smart-home hub. Consumes the ESPHome room-temperature sensors via the MQTT broker. Not managed from the IaC repo. |
| **DNS / Container manager / Reverse proxy** | on **[heimdall.lab](http://heimdall.lab)** (`192.168.10.4`) | `192.168.10.4` | **Pi-hole** ([pihole.lab](http://pihole.lab)) is the DNS server your device actually talks to — it does the ad-blocking and hands `.lab` names to **Technitium** ([technitium.lab](http://technitium.lab)) behind it. Also **Komodo** ([komodo.lab](http://komodo.lab), containers) and **Caddy** (reverse proxy). **Ask the administrator for the admin URLs.** |
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

Almost everything runs on **Hyperion**, a 10-node Raspberry Pi 5 Kubernetes
cluster. The storage (TrueNAS / Akasha) provides NFS volumes to the cluster —
and **Jellyfin itself still runs on Akasha**, not on the cluster, at
`192.168.10.247:30013`. If a link is down, check **Uptime Kuma** or ping a
platform admin.

---

## Naming reference (for admins)

The `*.lab` names resolve through **Pi-hole** on Heimdall (`192.168.10.4`),
which does the ad-blocking and forwards the `.lab` zone to **Technitium** behind
it. Records are seeded declaratively from `Heimdall/scripts/seed-zones.sh` —
note that script is **additive only**: it never corrects or deletes a record, so
a value edited in the Technitium UI survives a reseed.

Most apps' LoadBalancers also listen on **port 80** (in addition to their native
port) so the bare `http://<app>.lab` works without a port suffix — defined
per-service in `Hyperion/k8s/apps/**/service.yaml`. The exceptions, which need
their native port or a Caddy route, are **Immich** (`:2283`), **Subwave**
(`:7700–7702`), **agent-caldera** (`:8000`) and **Mosquitto** (`:1883`). The
`https://` links in this guide (`immich.lab`, `ignis.lab`, `subwave.lab`,
`sharedirstat.lab`) go through Caddy with its internal CA — your browser will
warn unless the lab root CA is installed (see
`Heimdall/docs/runbooks/trust-store-distribution.md`).
