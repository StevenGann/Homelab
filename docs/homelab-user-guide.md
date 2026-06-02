# Homelab — User Guide

*A hand-off reference for trusted users with admin access. Last updated 2026-06-01.*

All services below run on the home network (`192.168.10.0/24`) — open the links
while connected to the LAN (or through the remote-access method the administrator
gave you). They are **not** exposed to the public internet.

**Credentials:** ask the administrator. Most apps have their own login (often set
on first visit); a few share the standard internal-admin password. Treat every
link here as admin access — please don't change settings you don't understand.

> 💡 **Start here:** **[Homarr dashboard → http://192.168.10.53:7575](http://192.168.10.53:7575)** —
> the homelab home page; it links out to everything below.

---

## 🎬 Watch & Listen

| App | Link | What it's for |
|---|---|---|
| **Jellyfin** | [192.168.10.247:30013](http://192.168.10.247:30013) | The main media server — stream Movies, TV, and Music. This is what most people use day-to-day. |
| **Navidrome** | [192.168.10.66:4533](http://192.168.10.66:4533) | Dedicated music streaming (Subsonic-compatible — works with apps like DSub, play:Sub, Symfonium). |
| **Seerr** | [192.168.10.54:5055](http://192.168.10.54:5055) | **Request** new movies & shows. Search for something, click request, and it gets downloaded and added automatically. The friendliest way to add content. |

---

## 📺 Media Automation (the "*arr" apps)

These run the library behind the scenes — request something in **Seerr** and you
usually never need to touch these. Admin/power-user territory.

| App | Link | What it manages |
|---|---|---|
| **Sonarr** | [192.168.10.56:8989](http://192.168.10.56:8989) | TV shows — searches, downloads, renames, organizes episodes. |
| **Radarr** | [192.168.10.57:7878](http://192.168.10.57:7878) | Movies — same idea as Sonarr. |
| **Lidarr** | [192.168.10.65:8686](http://192.168.10.65:8686) | Music albums/artists. |
| **Kapowarr** | [192.168.10.60:5656](http://192.168.10.60:5656) | Comics & manga. |
| **Youtarr** | [192.168.10.61:3087](http://192.168.10.61:3087) | Archives YouTube channels/videos into the library. |
| **Prowlarr** | [192.168.10.55:9696](http://192.168.10.55:9696) | Indexer manager — the search sources the *arr apps use. Central config. |
| **Trailarr** | [192.168.10.63:7889](http://192.168.10.63:7889) | Downloads trailers for the movie/TV library. |
| **Tdarr** | [192.168.10.62:8265](http://192.168.10.62:8265) | Transcoding & library health (re-encodes files; heavy work runs on dedicated machines). |

---

## ⬇️ Downloads

| App | Link | What it's for |
|---|---|---|
| **qBittorrent** | [192.168.10.58:8085](http://192.168.10.58:8085) | The download client (runs through a VPN with a kill-switch). The *arr apps drive it automatically — you rarely need to open it. |
| **Cleanuparr** | [192.168.10.59:11011](http://192.168.10.59:11011) | Housekeeping — clears stalled/failed downloads automatically. |
| **SuggestArr** | [192.168.10.64:5000](http://192.168.10.64:5000) | Auto-suggests content based on what's been watched and feeds it to Seerr. |

---

## 📊 Dashboards & Monitoring

| App | Link | What it's for |
|---|---|---|
| **Homarr** | [192.168.10.53:7575](http://192.168.10.53:7575) | The homelab home page — quick links + at-a-glance status. **Bookmark this one.** |
| **Uptime Kuma** | [192.168.10.51](http://192.168.10.51) | Service status / uptime monitoring — is everything healthy? |
| **Headlamp** | [192.168.10.50](http://192.168.10.50) | Kubernetes dashboard — the cluster everything runs on (deep admin). |
| **Beszel** | [192.168.10.68:8090](http://192.168.10.68:8090) | Lightweight server/host monitoring (CPU, memory, disk, network). |
| **Speedtest Tracker** | [192.168.10.67](http://192.168.10.67) | Tracks internet speed over time (scheduled speedtests + history graphs). |

---

## 🤖 AI

| App | Link | What it's for |
|---|---|---|
| **Hermes** | [192.168.10.52](http://192.168.10.52) | Self-hosted AI agent (DeepSeek-backed). **Login required** (HTTP basic auth — ask the admin). |

---

## 🎮 Game Servers

| App | Link | What it's for |
|---|---|---|
| **Pterodactyl** | [192.168.10.69](http://192.168.10.69) | Game-server management panel. Create/manage servers (Minecraft, Rust, etc.). Game servers themselves run on dedicated "Wings" hosts (added separately). **Login required.** |

## 🛠️ Infrastructure (advanced — platform admins only)

| System | Link | What it's for |
|---|---|---|
| **TrueNAS (Akasha)** | [192.168.10.247](https://192.168.10.247) | The storage server — all media + app data lives here. |
| **DNS / Container manager / Reverse proxy** | on **Heimdall** (`192.168.10.4`) | Technitium (DNS + ad-blocking), Komodo (containers), and Caddy (reverse proxy) — reached via the reverse proxy; **ask the administrator for these URLs.** |

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

Everything except Jellyfin and the storage runs on **Hyperion**, a 10-node
Raspberry Pi 5 Kubernetes cluster. If a link is down, check **Uptime Kuma** or
ping a platform admin.
