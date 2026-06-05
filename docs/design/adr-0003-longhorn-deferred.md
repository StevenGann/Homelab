# ADR-0003: Longhorn Deferred — Local-Path Interim Storage Architecture

**Status:** Accepted  
**Date:** 2026-06-05  
**Supersedes:** None  
**Superseded by:** None (pending control-plane relocation)

## Context

All 10 Hyperion Pi 5 worker nodes have a 256GB NVMe SSD, partitioned as:
- 32GB root (`/`) — NixOS system, `/nix/store`
- ~200GB `/mnt/node-storage` (ext4) — available for persistent application data

We migrated several services to Akasha NFS (`root_squash`, `mapall 568:568` on media shares). Two problems emerged:

1. **`root_squash` + Linuxserver.io images**: Containers start as root, `chown` to PUID/PGID, but NFS `root_squash` maps root→nobody (65534), who cannot chown. Some images tolerate this silently; others crash-loop.
2. **SQLite latency over NFSv4.1**: Apps with SQLite databases (sonarr, radarr, lidarr, prowlarr) experience periodic liveness-probe kills (3-10 restarts/hour) due to NFS latency spikes exceeding the 5-second probe timeout.

## Decision

**Longhorn** (CNCF distributed block storage) is the chosen long-term solution. It provides:
- Cross-node replication (survives any single node failure)
- Native ext4 block devices (no `root_squash`, fast local SQLite)
- Works with the existing 200GB `/mnt/node-storage` on each node

**However**, Longhorn cannot be deployed until the k3s control plane is relocated. The current control plane runs in a bridge-networked Docker container on Heimdall (192.168.10.4). Longhorn's admission webhooks run as pods on worker nodes — the bridge-networked API server cannot reach them. This is documented in ADR-0002.

### Interim Architecture

Until the control plane is relocated, we use **local-path on `/mnt/node-storage`**:

| Storage Class | Target | Use Case |
|---------------|--------|----------|
| `local-path` (`/mnt/node-storage`) | All PVCs ≤10GB | Configs, SQLite DBs, small data |
| Akasha NFS (`mapall 568:568`) | PVCs >10GB or media | Downloads, media libraries, large caches |

### Current State (2026-06-05)

**On local-path (/mnt/node-storage):**
- sonarr-config (5Gi), radarr-config (2Gi), lidarr-config (2Gi), prowlarr-config (1Gi)
- cleanuparr-config (1Gi) — PUID=0 workaround for NFS chown, moved to local-path
- kapowarr-db (1Gi) — PUID=0 workaround, entrypoint chowns NFS downloads mount
- All remaining PVCs across all namespaces

**On Akasha NFS:**
- qbittorrent-config (1Gi) — working, not a DB
- tdarr-server/configs/logs (5+1+1Gi) — working
- jellystat-db (10Gi PostgreSQL) — NFS target (>10GB)
- musicseerr-cache (10Gi) — NFS target (>10GB)
- media-{tv,movies,music,comics,youtube,downloads} — NFS with mapall

### Known Workarounds (Remove After Longhorn)

1. **PUID=0/PGID=0**: cleanuparr and kapowarr deployments set PUID=0 to skip chown. Revert to PUID=568 after Longhorn migration.
2. **5-second probe timeouts**: *arr deployments have `timeoutSeconds: 5` on all probes. Can reduce to defaults after moving to Longhorn.
3. **Kapowarr temp_downloads**: `/app/temp_downloads` IS the NFS downloads mount. The entrypoint script chowns it recursively. PUID=0 skips this. After Longhorn, the entrypoint should be patched to not chown NFS mounts.

## Consequences

- **Positive**: SQLite services are stable (no restart churn). No `root_squash` issues. DiskPressure risk relieved by moving to 200GB partition.
- **Negative**: No cross-node replication. If a node fails, services with local-path PVCs on that node cannot reschedule until the node recovers. This is acceptable for homelab use during the interim period.
- **Risk**: The `/mnt/node-storage` partition could fill if services store unexpected data (see kapowarr 125GB download bomb, qBittorrent 21GB config PVC). Mitigation: `emptyDir` size limits and monitoring.

## Trigger for Revisiting

When the k3s control plane is relocated from the bridge-networked Docker container to a real host (dedicated Pi, host networking, or Heimdall bare metal):

1. Deploy Longhorn via manifest
2. Set Longhorn as default StorageClass
3. Migrate all ≤10GB PVCs from local-path to Longhorn
4. Remove PUID=0 workarounds
5. Reduce probe timeouts to defaults
6. Archive this ADR
