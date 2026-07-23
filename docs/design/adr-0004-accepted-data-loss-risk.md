# ADR-0004: Accept the data-loss risk for stateful workloads (no backups)

- **Status:** Accepted
- **Date:** 2026-07-04
- **Context:** the DR reconciliation audit (`docs/dr-readiness-2026-07-04.md`,
  findings C4/C5) established that **no backup of any persistent data exists** in
  the homelab.

## Decision

The operator has **explicitly accepted** the current no-backup posture rather
than build a backup system at this time. This is a recorded decision, not an
oversight.

## What this accepts as expendable / re-acquirable

**On a single Pi NVMe failure** (every k8s PVC is node-local `local-path`,
single-replica, `reclaimPolicy=Delete`, no replication): the databases and
app state on that node are permanently lost and Flux recreates only empty pods —
*arr SQLite (sonarr/radarr/lidarr/prowlarr), jellystat PostgreSQL, pterodactyl &
nextcloud & romm MariaDB, n8n workflow state, uptime-kuma/beszel monitoring
history, navidrome, speedtest-tracker, youtarr, kapowarr, caldera vault.

**On Akasha (TrueNAS) loss** (no ZFS snapshot/replication, config not in git):
the entire ~6 TB media library, **all Nextcloud user files**, and the Heimdall
infra backups (`backup.sh` writes *into* Akasha) are lost.

**On Thoth disk loss:** Minecraft worlds + `wings.db` under `/var/lib/pterodactyl`;
OpenWebUI users/chats. (Ollama models on `/tank` are re-pullable.)

## Rationale

Media is re-acquirable; the estate is a homelab, not production; the operator
prefers to defer backup engineering. The Longhorn migration remains deferred
(see [ADR-0003](adr-0003-longhorn-deferred.md)).

## Consequences / revisit triggers

- **Nextcloud user files** and **game-server worlds** are *not* obviously
  "re-acquirable" — if these gain irreplaceable content, revisit this ADR and
  add at least a targeted `restic`/`zfs-send` job for those paths.
- The single unbacked-up item with no re-acquire path is the **operator age key**
  — that one **must** be backed up off-site regardless (see
  [`docs/runbooks/disaster-recovery.md`](../runbooks/disaster-recovery.md) §0).
- If/when this is reversed: deploy committed DB-dump CronJobs to Akasha
  Infra-Storage, move the Heimdall backup destination off Akasha, and configure
  Akasha ZFS snapshots + an off-host replication target.
