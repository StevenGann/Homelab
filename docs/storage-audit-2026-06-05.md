# Storage Audit — local-node persistent data on Hyperion (2026-06-05)

**Trigger:** qBittorrent wrote 21.5 GB of downloads into its *config* PVC
(`qbittorrent-config`, a `local-path` volume on `hyperion-theta`'s 32 GB NVMe).
The disk filled, the kubelet raised **DiskPressure**, and every pod on theta was
evicted. This audit catalogs ALL persistent data on local node storage and the
migration to Akasha NFS.

## Rule being enforced

> No Hyperion k3s service may keep persistent data on a node's local NVMe.
> All persistent data (configs, databases, downloads) lives on Akasha
> (`192.168.10.247`) via NFS. Only genuinely-ephemeral scratch (small caches,
> transcode temp, VPN runtime state) may use node-local `emptyDir`, and it must
> be size-capped so it can never fill a node disk.

## Cluster facts

- StorageClasses: only `local-path (default)` existed at audit time. No NFS SC.
- Existing NFS (the good pattern): the `media` namespace already mounts the
  Akasha media datasets as **static** NFS PV+PVC pairs (`akasha-*-nfs`,
  RWX, Retain) — see `Hyperion/k8s/apps/media/00-storage/`.
- Akasha NFS exports (via `showmount`):
  - `/mnt/Media-Storage/Media/{Downloads,TV-Shows,Movies,Music,Comics,YouTube,Audiobooks}` — `mapall 568:568`, already used by media.
  - `/mnt/Media-Storage/Application-Storage` — exported to `*`, **root_squash**
    (root→65534), root dir mode `0777`. **This is the target for all app config/DB
    data.** Because it is root_squash (not `mapall 568`), subdirectories must be
    created/populated *as UID 568* so the app (which runs as 568) owns its files.
  - `/mnt/Media-Storage/Infra-Storage` — Heimdall backups; not for app data.
  - `/mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root` — control-plane only.
- All 13 affected workloads are **single-replica Deployments** (no StatefulSets) —
  simplifies migration (scale to 0, copy, swap PVC, scale up).

## Findings — persistent data on local-path (37 PVCs, 13 namespaces)

| Namespace | PVC | Size | Workload | Data type | NFS target subpath |
|-----------|-----|------|----------|-----------|--------------------|
| beszel | beszel-data | 1Gi | beszel | SQLite (monitoring hub) | beszel/beszel-data |
| boxarr | boxarr-config | 2Gi | boxarr | config | boxarr/boxarr-config |
| caldera | caldera-data | 1Gi | caldera | config | caldera/caldera-data |
| caldera | caldera-vault | 2Gi | caldera | config | caldera/caldera-vault |
| hermes | hermes-data | 5Gi | hermes | app data | hermes/hermes-data |
| jellystat | jellystat-db | 10Gi | jellystat-db | **PostgreSQL** | jellystat/jellystat-db |
| jellystat | jellystat-backup | 5Gi | jellystat | backups | jellystat/jellystat-backup |
| listenarr | listenarr-config | 5Gi | listenarr | config | listenarr/listenarr-config |
| media | cleanuparr-config | 1Gi | cleanuparr | config | media/cleanuparr-config |
| media | homarr-appdata | 1Gi | homarr | config | media/homarr-appdata |
| media | kapowarr-db | 1Gi | kapowarr | SQLite | media/kapowarr-db |
| media | lidarr-config | 2Gi | lidarr | SQLite | media/lidarr-config |
| media | navidrome-data | 2Gi | navidrome | SQLite | media/navidrome-data |
| media | prowlarr-config | 1Gi | prowlarr | SQLite | media/prowlarr-config |
| media | qbittorrent-config | 1Gi | qbittorrent | config (+stray dl) | media/qbittorrent-config |
| media | radarr-config | 2Gi | radarr | SQLite | media/radarr-config |
| media | seerr-config | 2Gi | seerr | config | media/seerr-config |
| media | sonarr-config | 5Gi | sonarr | SQLite | media/sonarr-config |
| media | suggestarr-config | 1Gi | suggestarr | config | media/suggestarr-config |
| media | tdarr-configs | 1Gi | tdarr | config | media/tdarr-configs |
| media | tdarr-logs | 1Gi | tdarr | logs | media/tdarr-logs |
| media | tdarr-server | 5Gi | tdarr | DB/server | media/tdarr-server |
| media | trailarr-config | 2Gi | trailarr | config | media/trailarr-config |
| media | youtarr-config | 2Gi | youtarr | config | media/youtarr-config |
| media | youtarr-db | 2Gi | youtarr | DB | media/youtarr-db |
| musicseerr | musicseerr-config | 5Gi | musicseerr | config | musicseerr/musicseerr-config |
| musicseerr | musicseerr-cache | 10Gi | musicseerr | cache (large) | musicseerr/musicseerr-cache |
| n8n | n8n-data | 5Gi | n8n | SQLite | n8n/n8n-data |
| pterodactyl | pterodactyl-db | 5Gi | mariadb | **MariaDB** | pterodactyl/pterodactyl-db |
| pterodactyl | pterodactyl-var | 2Gi | panel | config | pterodactyl/pterodactyl-var |
| sortarr | sortarr-config | 2Gi | sortarr | config | sortarr/sortarr-config |
| speedtest-tracker | speedtest-config | 1Gi | speedtest-tracker | SQLite | speedtest-tracker/speedtest-config |
| uptime-kuma | uptime-kuma-data | 2Gi | uptime-kuma | SQLite | uptime-kuma/uptime-kuma-data |

### emptyDir / hostPath review (NOT persistent — acceptable, with one cap added)

- `emptyDir`: flux controllers (temp/data caches), traefik, metrics-server,
  qbittorrent `gluetun-state`/`gluetun-port` (VPN runtime state), **tdarr `temp`
  (transcode scratch — can grow large)**. All ephemeral. Action: add a
  `sizeLimit` to the tdarr `temp` emptyDir so a runaway transcode cannot fill a
  node disk (the same failure class as the qBittorrent incident).
- `hostPath`: beszel-agent (`/proc`,`/sys`,`/` read-only host introspection —
  legitimate for a monitoring agent), qbittorrent `/dev/net/tun` (VPN device).
  Debug pods (`disk-check`, `node-debugger`, `theta-debug`) — transient, deleted.
  None store persistent app data. No action.

### Incident cleanup

- 31 `Evicted` + 1 `ContainerStatusUnknown` qBittorrent pods (DiskPressure
  fallout) deleted. qBittorrent itself was stuck `Pending`: its `local-path`
  config PV is pinned to one node by PV node-affinity, so it could not
  reschedule — a direct illustration of why config must be RWX NFS.

## Migration approach

**Static NFS PV+PVC per service** (matches the existing `akasha-*-nfs`
convention; fully reviewable in Git), data pre-copied into
`/mnt/Media-Storage/Application-Storage/<namespace>/<pvc>` by a migration Job
running as UID 568. PVC **names are unchanged**, so deployment manifests don't
change — only each `pvc.yaml` flips from `local-path` to a static NFS PV.

Per service: scale Deployment → 0, run copy Job (old PVC → NFS subpath), repoint
`pvc.yaml`, delete old local-path PVC, let Flux recreate it bound to the NFS PV,
scale up, verify. Committed one service per commit.

## Risks documented

- **DBs over NFS** (jellystat PostgreSQL, pterodactyl MariaDB): supported with
  NFSv4.1 **hard** mounts + locking (which we use), but carries performance and
  locking caveats vs local disk. Migrated per the mandate; flagged for possible
  future move to a TrueNAS-native DB or iSCSI zvol if contention appears.
- **SQLite over NFS** (*arr apps, n8n, uptime-kuma, beszel): works with NFSv4
  locking; `hard` mounts prevent corruption on transient network blips.
- Cannot modify Akasha exports (no admin access from this host), so the
  root_squash export is used as-is; ownership handled by populating as UID 568.

## Prevention (Phase 3)

1. Demote `local-path` from default StorageClass (a PVC with no class fails loud
   instead of silently grabbing local NVMe).
2. **ValidatingAdmissionPolicy** (built into k3s 1.34, no Kyverno needed) that
   **denies any new PVC with `storageClassName: local-path`**.
3. Cap the tdarr transcode `emptyDir` with a `sizeLimit`.
4. All app `pvc.yaml` manifests in `Hyperion/k8s/apps/**` converted to NFS.
