# *arr Stack Deployment Plan — Hyperion (Pi 5 / k3s) + Akasha (TrueNAS)

> Produced 2026-06-01 by an 18-agent research workflow (one deep-dive per
> service + arm64-matrix / storage / GitOps / integration cross-cuts), verified
> against live registry manifests and the existing repo conventions. This is a
> **planning document for operator review** — see §8 for the decisions to
> confirm before we build. Nothing here is deployed yet.

Target: Hyperion 10-node Pi 5 k3s cluster (arm64), FluxCD GitOps, plain kustomize, single VLAN 192.168.10.0/24. Media library + downloads dir + Jellyfin + qBittorrent stay on **Akasha (192.168.10.247)**. Verified against live registry manifests 2026-06-01 and the existing repo conventions (`headlamp`/`uptime-kuma`/`hermes` pattern, MetalLB pool `.10–.99`, `topology.kubernetes.io/zone=hyperion`).

---

## 1. Executive summary + placement

The verdict is overwhelmingly **Hyperion**. Eleven of the thirteen services are lightweight .NET/Node/Python/Go controllers that do pure HTTP API work and never touch a video frame — textbook Pi-5/arm64 tenants. The only services with a *real* argument against Hyperion are the two that transcode video continuously: **Tunarr** (live IPTV transcode) and **Tdarr's worker/transcode** (Tdarr's *server* is fine on Pi; its workers are not). Everything else goes on Hyperion in a shared `media` namespace, reaching Akasha media+downloads over a single NFS mount.

**The central design decision is storage, not placement** — see §3. Get the single-`/data`-mount + hardlink design right and the rest is boilerplate.

| Service | Placement | One-line reason |
|---|---|---|
| **Prowlarr** | Hyperion | Indexer proxy; pure HTTP, tiny SQLite, clean arm64. No media access. |
| **Sonarr** | Hyperion | TV PVR; arm64-native .NET, no transcode. Reaches Akasha media+downloads via NFS. |
| **Radarr** | Hyperion | Movie PVR; same profile as Sonarr. |
| **Jellyseerr ("Seerr")** | Hyperion | Request UI; Node, API-only, arm64-native. No media locality pull. |
| **Cleanuparr** | Hyperion | Queue janitor; .NET, API-only. Disable the hardlink/orphan cleaner OR NFS-mount downloads. |
| **SuggestArr** | Hyperion | Recommender glue; tiny Python, API-only. |
| **Notifiarr** | Hyperion | Go notification relay; API-only. Needs a **stable pod hostname** (identity footgun). |
| **Kapowarr** | Hyperion | Comic manager; Python, arm64. Needs Akasha NFS for comic lib + temp on one filesystem. |
| **Youtarr** | Hyperion | YouTube grabber; arm64. yt-dlp+ffmpeg remux is CPU-bursty but acceptable. Bundles MariaDB. |
| **Homarr** | Hyperion | Dashboard; arm64. ~600 MB idle RAM — heavy for a dashboard, budget for it. |
| **Trailarr** | Hyperion | Trailer fetcher; arm64. ffmpeg is CPU-only on Pi but trailers are short — cap concurrency. |
| **Tdarr (server only)** | Hyperion | Coordinator/UI/DB is light; run `internalNode=false`. **Workers must NOT run on Pi.** |
| **Tdarr (worker/transcode)** | **Akasha** | **STRONG against Hyperion:** arm64 image ships ancient ffmpeg 4.4.2 (av1 hangs), no usable HW transcode in Pi pods. Put transcode on x86. |
| **Tunarr** | **Akasha** | **STRONG against Hyperion:** continuous software ffmpeg transcode (no Pi HW encode), wants direct local media access, and ships arm64 only as a separate `-arm64` tag. |

**Services with a STRONG argument against Hyperion (call-outs):**
- **Tunarr** — three strikes: (1) no arm64 multi-arch manifest (`-arm64` tag only); (2) no Pi/rkmpp HW transcode backend, so software-only encode that "saturates multiple cores per 1080p stream"; (3) wants direct filesystem access to the same paths Jellyfin sees (media on Akasha). Recommend Akasha. If it must go on Hyperion, treat it as "1–2 concurrent 1080p direct-stream channels, no 4K" and read-only NFS-mount the library with path replacement.
- **Tdarr transcode** — server-on-Pi is genuinely viable (the arm64 server manifest is real and the server doesn't transcode when `internalNode=false`). But the *transcode workers* are the point of Tdarr and the Pi arm64 node ships a crippled ffmpeg (issue #1101) with no container HW accel. Run workers on Akasha/x86.
- No other service has an arm64 or transcode blocker. Media-locality services (Sonarr/Radarr/Kapowarr/Trailarr/Youtarr/Tdarr-server) all *write* to Akasha but the file I/O executes server-side on Akasha's ZFS — see §3 — so locality is satisfied by the NFS design, not by moving the app.

---

## 2. arm64 reality check — problem children + fallbacks

Nine services are true multi-arch with first-class arm64 and zero caveats: **Prowlarr, Sonarr, Radarr, Jellyseerr, Cleanuparr, SuggestArr, Notifiarr, Kapowarr, Homarr**. Deploy as-is.

| Problem child | The gap | Fallback / mitigation |
|---|---|---|
| **Tunarr** | `:latest` is **amd64-only**; no unified manifest. Plus software-only transcode on Pi. | Hardcode the `-arm64` suffix in the kustomize `image:` field (e.g. `chrisbenincasa/tunarr:1.0.14-arm64`). Better: deploy on Akasha. On Pi only if channels are "direct stream / no transcode." |
| **Tdarr (node/transcode)** | arm64 image exists but ships ffmpeg 4.4.2 (libaom-av1 hangs at 100% CPU, no libsvtav1); no container HW transcode on Pi 5 (VideoCore not exposed to pods). | Run **server** on Hyperion (`internalNode=false`). Run **workers** on Akasha/x86. Do not rely on Pi nodes for real transcode. (Option C: custom arm64 image with jellyfin-ffmpeg 7 + software-only ~14 fps SVT-AV1 — not recommended.) |
| **Trailarr** | arm64 image real; bundled NVIDIA/VAAPI HW-accel drivers are inert on Pi → CPU-only ffmpeg. | Acceptable: trailers are short 1–3 min clips. Mitigate by setting output codec to VP9/Opus (matches YouTube source) so most downloads skip conversion. Cap concurrency. Not a blocker. |
| **Youtarr** | arm64 real; yt-dlp+ffmpeg remux is CPU/IO-bound; bundled MariaDB. | Acceptable for occasional downloads. Use upstream's `docker-compose.arm.yml` pattern → **named-volume / PVC MariaDB, never a bind mount** (overlay-FS corruption risk). Use `DATA_PATH` single-mount mode for k8s. |

**Pin discipline (all):** use explicit version tags, never `:latest`/`:develop`/`:nightly`, so Flux reconciles deterministically. FlareSolverr (if you ever add it to Prowlarr) is the real arm64 risk in this stack — pin a known-good tag (v3.3.22 per FlareSolverr #1509); Prowlarr itself is unaffected.

---

## 3. Storage architecture — THE central decision

**Decision: one TrueNAS dataset, exported ONCE over NFS, mounted into every media-touching pod at a single `/data` root. Static hand-written NFS PV/PVC (RWX), not democratic-csi. App `/config` stays on k3s `local-path` (node-local, RWO, never NFS).**

### Why this works across the host boundary
Hardlinks and atomic moves are evaluated **server-side on Akasha's ZFS**, where the inodes live — the Hyperion↔Akasha network boundary is irrelevant. What matters is that, *as seen through one NFS mount*, `/data/torrents/tv` and `/data/media/tv` are the **same filesystem**. They are, because they're subdirectories of one dataset exported once. The only thing crossing the network is the NFS mount; all hardlink/move I/O happens locally on Akasha. ([TRaSH hardlinks](https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/))

### The canonical layout (one dataset `pool/data`)
```
data/
├── torrents/{movies,tv,music,books}   ← qBittorrent (on Akasha) writes here
├── usenet/{incomplete,complete/...}   ← if you add Usenet later
└── media/{movies,tv,music,books}      ← Sonarr/Radarr organize into here
```

### The two anti-patterns that silently kill hardlinks (and break this homelab)
1. **Two mounts** — mounting `/downloads` + `/media` separately, or two PVCs even from the same export → pod sees two filesystems → *arr falls back to copy+delete (doubles space, slow over NFS, breaks seed-while-imported). **Mount only `/data`.**
2. **Two NFS exports** for torrents vs media → looks like two filesystems → same failure. **One export.**

### Why NFS-static, not democratic-csi
The media share is one big pre-existing dataset you manage by hand — not dynamic per-app storage. democratic-csi's value is *dynamic per-PVC dataset provisioning*, which is the wrong model for "one shared library every app RWX-mounts." A static NFS PV is zero extra cluster components and trivially shared. Keep democratic-csi in your back pocket only if you later want TrueNAS-backed dynamic config PVCs — but config should be local-path anyway (SQLite over NFS corrupts).

### Manifest shape (the load-bearing pieces)
```yaml
# ONE static PV for the single Akasha /data export — RWX, shared by all media pods
apiVersion: v1
kind: PersistentVolume
metadata: { name: akasha-data-nfs }
spec:
  capacity: { storage: 1Ti }          # nominal; NFS ignores it
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""                 # static, no provisioner
  mountOptions: [nfsvers=4.1, hard, nconnect=4]
  nfs: { server: 192.168.10.247, path: /mnt/pool/data }   # the ONE export
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: akasha-data, namespace: media }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: akasha-data-nfs          # bind to the static PV
  resources: { requests: { storage: 1Ti } }
---
# Per-app config on node-local storage (NOT NFS — SQLite locking)
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: sonarr-config, namespace: media }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 5Gi } }
```
Pod side (every media-touching deployment):
```yaml
spec:
  strategy: { type: Recreate }                       # RWO local-path config pins to a node
  template:
    spec:
      nodeSelector: { topology.kubernetes.io/zone: hyperion }   # MANDATORY
      securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 }
      containers:
        - name: sonarr
          image: lscr.io/linuxserver/sonarr:4.0.x-lsNN          # pin
          env: [ {name: PUID, value:"1000"}, {name: PGID, value:"1000"}, {name: UMASK, value:"002"} ]
          volumeMounts:
            - { name: data,   mountPath: /data }     # SINGLE mount — the whole tree
            - { name: config, mountPath: /config }
      volumes:
        - { name: data,   persistentVolumeClaim: { claimName: akasha-data } }
        - { name: config, persistentVolumeClaim: { claimName: sonarr-config } }
```

### Remote Path Mappings (qBittorrent on Akasha)
**Best practice: avoid them entirely.** Make qBittorrent on Akasha mount the dataset at `/data` too and save to `/data/torrents/...`. Then qBittorrent reports `/data/torrents/tv`, the *arr pod sees `/data/torrents/tv` — paths match, no mapping needed. If qBittorrent instead reports an Akasha-native path, add in each *arr a Remote Path Mapping:
```
Host: 192.168.10.247   Remote: /mnt/pool/data/torrents/   Local: /data/torrents/
```
Critical: path mapping only rewrites the string — the *arr **still needs the NFS mount** to actually read/write/hardlink. Both requirements are independent; you need both.

### Permissions — the cross-host glue (three layers, one UID/GID)
Pick **1000:1000 / umask 002** everywhere:
1. ***arr pods (Hyperion):** LSIO `PUID=1000 PGID=1000 UMASK=002` + k8s `securityContext fsGroup:1000`.
2. **qBittorrent (Akasha):** same `1000:1000 / 002` so completed files are group-writable.
3. **TrueNAS NFS export:** own `pool/data` as `1000:1000`, perms `775`/`664`, **and set Mapall User=1000 / Mapall Group=1000** on the NFS share (Advanced). `mapall` squashes every NFS client identity to that user, sidestepping the "UID 1000 on the Pi ≠ UID 1000 on TrueNAS" mismatch. Do **not** also SMB-share the same dataset (mixed NFS+SMB perms = chaos).

**Exceptions to PUID/PGID:** Jellyseerr runs as UID 1000 (set `fsGroup:1000`, no PUID env). SuggestArr and Kapowarr/Trailarr are not LSIO images — Kapowarr/Trailarr default to root, so set their PUID/PGID (Kapowarr) or match the NFS uid/gid (Trailarr) explicitly or files land root-owned.

---

## 4. GitOps / repo layout

Stay with **plain kustomize** — the repo has no Helm/HelmRelease infra and the `headlamp`/`uptime-kuma`/`hermes` convention is clean and working. (app-template/bjw-s is the right answer only if this grows to dozens of apps; revisit then.) Use **one shared `media` namespace** so apps resolve each other by short DNS (`http://sonarr.media.svc.cluster.local`) — this diverges from the repo's per-app-namespace habit, and that divergence is correct for a co-operating stack.

```
Hyperion/k8s/apps/media/
  namespace.yaml                 # ns: media
  kustomization.yaml             # lists nfs-pv + all subdirs
  nfs/akasha-data-pv.yaml        # the single static RWX NFS PV (cluster-scoped)
  prowlarr/   { deployment, service, pvc, secret.sops.yaml }
  sonarr/     { deployment(+/data NFS), service, pvc, secret.sops.yaml }
  radarr/     { same shape }
  jellyseerr/ { deployment, service, pvc, secret.sops.yaml }
  cleanuparr/ { deployment, service, pvc, secret.sops.yaml }
  suggestarr/ { deployment, service, pvc }            # secrets live in its SQLite, no env keys
  notifiarr/  { deployment(+hostname), service, pvc, secret.sops.yaml }
  kapowarr/   { deployment(+/data NFS), service, pvc(db) }
  youtarr/    { deployment+mariadb, service, pvc(config+db), (+/data NFS output) }
  homarr/     { deployment, service, pvc, secret.sops.yaml }   # SECRET_ENCRYPTION_KEY
  trailarr/   { deployment(+/data NFS), service, pvc, secret.sops.yaml }
  tdarr/      { deployment(server, internalNode=false, +/data NFS+cache), service, pvc }
  # tunarr/   → deploy on AKASHA, not here (see §1). If on Pi: -arm64 tag, RO /data.
```

One Flux Kustomization in `clusters/hyperion/apps.yaml`, mirroring the `hermes` entry (it already has the SOPS decryption block):
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: media, namespace: flux-system }
spec:
  interval: 10m
  path: ./Hyperion/k8s/apps/media
  prune: true
  wait: true
  timeout: 10m                       # first-boot SQLite + NFS mount on arm64
  dependsOn: [{ name: metallb-config }]
  sourceRef: { kind: GitRepository, name: flux-system }
  decryption: { provider: sops, secretRef: { name: sops-age } }
```

**SOPS secret pattern (the load-bearing finding):** seed each *arr's API key deterministically via the `<APP>__AUTH__APIKEY` env var. Sonarr/Radarr/Prowlarr read it on a fresh `/config` before generating a random key (confirmed via Whisparr #992 — their `AuthOptions`/`ConfigFileProvider` honors it). One `secret.sops.yaml` per app with `stringData: { SONARR__AUTH__APIKEY: <uuidgen> }`, consumed via `envFrom: [{ secretRef: { name: sonarr-secret }}]`. Encrypt **only `data`/`stringData`**, metadata plaintext, no comments — per the homelab SOPS rule. There is **no `_FILE` variant** (Radarr #11157) — inject via env, not a file. Because you mint the keys yourself, all downstream wiring (Prowlarr→arr, Jellyseerr→arr, Homarr→arr) is known at deploy time. Generate keys with `uuidgen | tr -d -`.

**Probes:** use `GET /ping` (returns 200 without the API key) for liveness+readiness on Sonarr 8989 / Radarr 7878 / Prowlarr 9696. Add a `startupProbe` with generous `initialDelaySeconds` (30–45s) for first-boot SQLite migration on slow arm64 storage. Don't probe `/` (may redirect/require auth).

**MetalLB LB IP plan** (`.50`/`.51`/`.52` already taken by headlamp/uptime-kuma/hermes). Only assign LB IPs to UIs you want directly on the LAN; everything else is ClusterIP behind Heimdall Caddy:

| IP | Service | IP | Service |
|----|---------|----|---------|
| .53 | Homarr (landing page) | .58 | Kapowarr |
| .54 | Jellyseerr | .59 | Youtarr |
| .55 | Prowlarr | .60 | Tdarr (UI 8265 + node 8266 must be LAN-reachable) |
| .56 | Sonarr | .61 | Cleanuparr |
| .57 | Radarr | .62 | Trailarr / SuggestArr / Notifiarr (or keep ClusterIP) |

---

## 5. Per-service deployment spec

Pin tags at build time; versions below are the current-stable lines as of research. All set `nodeSelector zone=hyperion`, `strategy Recreate`, config on `local-path`.

| Service | Image (pin a tag) | arm64 | req CPU/mem | lim CPU/mem | Config PVC | Port | LB IP | Key env/secret | Deps |
|---|---|---|---|---|---|---|---|---|---|
| Prowlarr | `lscr.io/linuxserver/prowlarr` | ✅ | 100m/128Mi | 500m/512Mi | 1Gi | 9696 | .55 | `PROWLARR__AUTH__APIKEY`, PUID/PGID/TZ | Sonarr, Radarr |
| Sonarr | `lscr.io/linuxserver/sonarr` | ✅ | 100m/256Mi | 1/1Gi¹ | 5Gi | 8989 | .56 | `SONARR__AUTH__APIKEY`, PUID/PGID/TZ + `/data` NFS | Prowlarr, qBit, Jellyfin |
| Radarr | `lscr.io/linuxserver/radarr` | ✅ | 100m/256Mi | 1/768Mi | 2Gi | 7878 | .57 | `RADARR__AUTH__APIKEY`, PUID/PGID/TZ + `/data` NFS | Prowlarr, qBit, Jellyfin |
| Jellyseerr | `fallenbagel/jellyseerr`² | ✅ | 100m/128Mi | 1/512Mi | 2Gi | 5055 | .54 | API keys (Sonarr/Radarr/Jellyfin) in SOPS; runs UID 1000 | Jellyfin, Sonarr, Radarr, TMDB |
| Cleanuparr | `ghcr.io/cleanuparr/cleanuparr` | ✅ | 50m/64Mi | 500m/384Mi | 1Gi | 11011 | .61 | arr+qBit API in SOPS; PUID/PGID/TZ | Sonarr/Radarr, qBit |
| SuggestArr | `ciuse99/suggestarr:v2.8.0` | ✅ | 100m/128Mi | 500m/512Mi | 1Gi | 5000 | — | none (config in SQLite wizard); no PUID support | Jellyseerr, Jellyfin, TMDB |
| Notifiarr | `golift/notifiarr` | ✅ | 50m/64Mi | 500m/256Mi | 1Gi | 5454 | — | Notifiarr.com API key; **`spec.hostname: notifiarr`** | Notifiarr.com, arrs, Jellyfin |
| Kapowarr | `mrcas/kapowarr:v1.3.1` | ✅ | 100m/128Mi | 500m/512Mi | 1Gi (db) | 5656 | .58 | PUID/PGID (default root!), TZ + `/data` NFS | ComicVine key, Komga/Kavita |
| Youtarr | `dialmaster/youtarr:v1.70.0` (+MariaDB) | ✅ | 250m/512Mi | 2/1Gi | 2Gi (config+DB) | 3087 | .59 | `DATA_PATH`, AUTH_PRESET_*, TRUST_PROXY + `/data` NFS output | MariaDB, Jellyfin/Plex |
| Homarr | `ghcr.io/homarr-labs/homarr` | ✅ | 200m/384Mi | 1/768Mi³ | 1Gi (/appdata) | 7575 | .53 | **`SECRET_ENCRYPTION_KEY`** (mandatory, SOPS) | all (consumer) |
| Trailarr | `nandyalu/trailarr` | ✅ | 250m/200Mi | 2/1Gi | 2Gi | 7889 | .62 | TZ, match NFS uid/gid + `/data` NFS RW | Radarr/Sonarr, YouTube |
| Tdarr (server) | `ghcr.io/haveagitgat/tdarr` | ✅ | 100m/256Mi | 1/512Mi | 5Gi (/app/server+configs) | 8265/8266 | .60 | `internalNode=false`, `serverIP=0.0.0.0`, PUID/PGID + `/data` NFS + shared `/temp` | Akasha/x86 worker nodes |
| **Tunarr** | `chrisbenincasa/tunarr:1.0.14-arm64`⁴ | ⚠️ `-arm64` only | — | — | 5–10Gi (prune backups!) | 8000 | — | **Prefer Akasha** | Jellyfin |

¹ Do **not** set Sonarr's mem limit tight — it has a history of OOM-kills when capped aggressively (Sonarr forum #8180). ² Or `ghcr.io/seerr-team/seerr` (merged "Seerr", Feb 2026; auto-migrates) — operator decides, see §8. ³ Homarr idles ~600 MB (issue #3759); watch it. ⁴ Tunarr on Pi only as a fallback — read-only `/data` NFS + path replacement, direct-stream channels only.

---

## 6. Integration topology + bring-up order

**Credential flow:** every consumer needs the *producer's* API key. Mint the arr keys yourself via SOPS (§4), so you know them before any pod starts. qBittorrent uses **WebUI username/password, not an API key**. Jellyfin key from Admin > Dashboard > API Keys. Sonarr/Radarr → Jellyfin uses the **Emby/Jellyfin** Connect type (no native Jellyfin connector; the notification path has a 404 history — treat library-refresh-on-import as "verify, don't assume," fall back to Jellyfin's scheduled scan).

Bring up producers before consumers:

1. **(Pre-req, Akasha) Jellyfin + qBittorrent** — confirm Jellyfin API key + qBittorrent WebUI creds + the `/data` mount path the arrs will share.
2. **Prowlarr** — no upstream deps; add indexers.
3. **Sonarr + Radarr** — set root folders on `/data/media/...`; add qBittorrent (WebUI creds + category); add Emby/Jellyfin Connect (Jellyfin key).
4. **Prowlarr → Sonarr/Radarr sync** — in Prowlarr > Apps add each arr (target arr's API key + Prowlarr's own key), run "Sync App Indexers." Indexers are managed *only* in Prowlarr.
5. **Jellyseerr** — connect Jellyfin (auth + library state), Sonarr, Radarr (API keys); map quality profiles + root folders.
6. **SuggestArr** — needs Jellyfin + Jellyseerr live + TMDB key; targets Jellyseerr, not the arrs directly.
7. **Cleanuparr** — needs arrs + qBittorrent; if enabling the orphan/hardlink cleaner, NFS-mount `/data` identically (else leave that feature OFF — start in dry-run).
8. **Trailarr** — needs arrs + `/data` NFS RW; mount paths must mirror what the arrs report.
9. **Kapowarr** — independent of the arrs (ComicVine + its own downloaders); needs `/data` NFS (comic root + temp on one filesystem).
10. **Youtarr** — needs MariaDB + `/data` NFS output; Jellyfin is passive (NFO-based, no push refresh — set NFO as preferred metadata in Jellyfin).
11. **Tdarr (server)** — needs `/data` NFS + shared `/temp`; register Akasha/x86 worker nodes pointing at `:8266`.
12. **Notifiarr** — wire arr Connect entries + Jellyfin Webhook plugin (passthrough only, not deep) + Discord (cloud-side). Set a **stable pod hostname** or the cloud spawns duplicate clients every restart.
13. **Homarr** — last; add every service's API key/creds. No auto-discovery — you paste keys you already control.

---

## 7. Phased rollout (with Flux gates)

Consistent with the existing Flux workflow: each phase is a commit to `main`, Flux reconciles, verify before proceeding. The `media` Flux Kustomization has `wait: true` so a phase won't report Ready until pods pass probes.

**Phase 0 — storage + namespace (foundation).** On Akasha: create `pool/data` with the TRaSH tree, own 1000:1000, single NFS export with mapall=1000. Repoint qBittorrent to save under `/data/torrents/...`. In repo: `namespace.yaml` + `nfs/akasha-data-pv.yaml` + the `media` Flux Kustomization. **Gate:** PV is `Available`, a throwaway test pod mounts `/data` RWX and can write a file Akasha sees as owned 1000:1000.

**Phase 1 — core triangle (Prowlarr + Sonarr + Radarr).** **Gate:** all three `/ping` healthy; Prowlarr app-sync pushes indexers into both arrs; a manual grab in Sonarr downloads via qBittorrent and **imports via hardlink** (verify `ls -li` shows link count 2 on Akasha, not a copy). This is the make-or-break gate for the whole storage design.

**Phase 2 — request + maintenance (Jellyseerr + Cleanuparr).** **Gate:** Jellyseerr authenticates against Jellyfin and a test request reaches Radarr; Cleanuparr connects to arrs+qBit (orphan cleaner OFF or dry-run).

**Phase 3 — enrichment (SuggestArr + Trailarr + Notifiarr).** **Gate:** SuggestArr submits a request through Jellyseerr; Trailarr writes a trailer next to a movie on `/data/media`; Notifiarr shows one stable client in the cloud dashboard (no dupes after a pod restart).

**Phase 4 — extras (Kapowarr + Youtarr + Tdarr-server).** **Gate:** Kapowarr files a test issue into `/data` via rename (not cross-FS copy); Youtarr downloads one video to `/data` output with MariaDB persisting; Tdarr server scans the library and an **off-Pi worker** connects on `:8266`.

**Phase 5 — dashboard + (optional, Akasha) Tunarr.** Homarr on `.53` wired to everything. Tunarr deployed on Akasha (or Pi `-arm64` fallback for ≤2 direct-stream channels).

---

## 8. Open decisions / risks — confirm before build

1. **NFS-static vs democratic-csi** — plan assumes static hand-written RWX NFS PV. Confirm. (Strong recommendation: static for the shared media share; democratic-csi adds friction for a RWX shared dataset.) **Needs confirming:** the exact TrueNAS export path (`/mnt/pool/data` is assumed) and that qBittorrent can be repointed to `/data/torrents/...`.
2. **Which "Seerr"** — legacy `fallenbagel/jellyseerr` (battle-tested, auto-migrates to merged code) vs forward `ghcr.io/seerr-team/seerr` (post-Feb-2026 merge). Both arm64. Recommend `fallenbagel/jellyseerr` pinned now, migrate later; operator call.
3. **Tdarr transcode location** — server-on-Pi is endorsed, but **workers must be off-Pi.** Confirm there's an x86 box or Akasha capacity for Tdarr nodes. If not, Tdarr is UI-only and does no useful work — reconsider deploying it at all.
4. **Tunarr** — confirm Akasha placement (recommended) vs Pi `-arm64` fallback. If on Pi, confirm expected concurrent-stream count is ≤2 and channels are direct-stream (no 4K, no heavy on-the-fly transcode). This is the single biggest "are you sure?" in the plan.
5. **qBittorrent path alignment** — confirm qBittorrent will mount Akasha at `/data` and save to `/data/torrents/...` so **no Remote Path Mapping is needed.** If it can't, we add the mapping (`192.168.10.247: /mnt/pool/data/torrents/ → /data/torrents/`) but the design is more fragile.
6. **UID/GID convention** — confirm 1000:1000 is free/usable on TrueNAS for the dataset owner, and that no existing Jellyfin/qBittorrent data is owned by a different UID (would need a `chown -R` on Akasha).
7. **Mixed protocol** — confirm `pool/data` will be NFS-only (not also SMB) to avoid permission chaos. If SMB access to the library is also wanted, that's a separate dataset or a documented risk.
8. **Plex-only / weak-Jellyfin flags** — (a) Sonarr/Radarr→Jellyfin via Emby connector has a 404 history; verify on import, fall back to scheduled scan. (b) Notifiarr's Jellyfin support is webhook-passthrough only (no rich API like Plex/Tautulli) — functional but shallow. (c) Youtarr gives Jellyfin no push refresh (NFO-passive only). None are blockers; all are "set expectations."
9. **Homarr RAM** — ~600 MB idle is high for a dashboard on a Pi; confirm the chosen node has headroom alongside other tenants.
10. **Cleanuparr orphan cleaner** — destructive deletes against the Akasha downloads share. Recommend leaving the hardlink/orphan cleaner OFF (queue-cleaner + blocklist-sync are API-only and need no mount). If enabled, dry-run/notify first. Operator decision.
11. **`Recreate` + node pinning** — every config-PVC pod pins to one node via local-path. With ~12 pods this concentrates the media stack onto a few Pis. Acceptable, but note if you want them spread you'd need anti-affinity (they can't move anyway while holding RWO local-path).

> Research-uncertainty flags: the Tdarr arm64 *server* manifest is genuinely real (the README's "nodes only" framing is misleading); the Sonarr→Jellyfin Emby-connector 404 history is real and intermittent; FlareSolverr (not in the deploy list, optional for Prowlarr) is the one arm64-fragile companion if you ever add it.
