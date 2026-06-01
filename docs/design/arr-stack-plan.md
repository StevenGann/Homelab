# *arr Stack on Hyperion — Implementation Plan (FINAL)

> **Team-reviewed final — 2 DEVELOPMENT-pipeline iterations + orchestrator-applied
> closing punch-list (2026-06-01).** Locked operator decisions: **NFS single export;
> Tdarr server on Hyperion + worker on Thoth; Tunarr shelved; seerr-team/seerr v3.0.1;
> UID/GID deferred.**
>
> This is the implementation-ready document. The iteration history (combined
> draft, iter-1/iter-2 revisions, adversarial reviews, vote tallies, FINAL.md)
> lives in the gitignored pipeline run folder
> `docs/pipeline-runs/20260601T093734Z-dev-arr-stack/`. The storage spine, arm64 facts, node-targeting,
> GitOps/SOPS layout, per-service specs, Tdarr server/worker wiring, integration
> order, and phased rollout were ACCEPTED in iteration 2; the iteration-3 closing
> punch-list (six convergent, no-disagreement vote objections) is folded in below.
>
> Load-bearing facts independently re-verified against primary sources / in-tree
> config this session (2026-06-01): GHCR registry API (`tags/list`), GitHub releases,
> nixpkgs `nfs.nix` @ release-25.11, seerr `server/lib/settings/index.ts`, Tdarr docs,
> and `Hyperion/nixos/hosts/*.nix` + `Hyperion/k8s/clusters/hyperion/apps.yaml`.

---

## 0. How findings were resolved (decision ledger — nothing dropped silently)

This ledger records the convergent dispositions only (conclusions, not the
thinking-out-loud). Full iteration-1/2 ledgers live in the superseded revision files.

### Iteration-3 closing punch-list (the only remaining vote objections — all convergent)

| ID | Fix | Where folded in |
|---|---|---|
| **PL-1 — canary Job lifecycle (unanimous NEW-B)** | The §2.5 canary is a `batch/v1` Job under a `prune:true/wait:true` Kustomization; a re-edited Job spec would hard-fail `field is immutable` and block `media-storage`. **FIX: `spec.ttlSecondsAfterFinished: 300`** so the Job self-deletes and re-renders clean on every `00-storage` change. Chosen default = ttl. Documented one-shot alternative (`kubectl delete job nfs-hardlink-canary` after PR-1). | §2.5, §4.3, §7.1 |
| **PL-2 — namespace stamping (NEW-A)** | `00-storage/kustomization.yaml` sets **NO top-level `namespace:`** — a deliberate divergence from the hermes pattern. The Namespace, PVC, and canary Job each carry `namespace: media` inline; the **cluster-scoped PV must carry none**. A top-level `namespace:` would make kustomize stamp `metadata.namespace` onto the PV. | §4.3, §4.4 |
| **PL-3 — §0 ledger scar (DA-2g)** | Conclusion only: **`media-storage` `dependsOn` is empty; `media-core` carries `dependsOn: [media-storage, metallb-config]`.** | §0 row below, §4.4 |
| **PL-4 — Youtarr MariaDB budget** | Model the bundled MariaDB as **its own container** with explicit resources (`requests 100m/256Mi`, `limits 500m/512Mi`) so the scheduler sees the real ~1.5 GiB pod footprint — memory limits are enforced on the Pis (`cgroup_enable=memory`), so an unbudgeted sidecar OOMs under buffer-pool pressure. | §5 (Youtarr row + footnote), §5 resource-sum check |
| **PL-5 — canary exercises the atomic move** | Extend the canary beyond hardlink (`ln` + `stat -c '%h %i'`): also `mv /data/torrents/tv/<probe> /data/media/tv/<probe2>` and assert no EXDEV — that cross-`torrents→media` rename is the actual *arr import syscall, distinct from hardlinking. | §2.5 |
| **PL-6 — honest single-apply framing** | Reword AC-A and all "single-apply" language to **"single-apply per tier; deliberate two-PR rollout (lean-core first, then opt-in extras after the ~1-week soak)."** The lean-core gate stays STRUCTURAL: the `media-extras` Flux Kustomization pointer is NOT authored in PR-1. | §4.2, §7, §11 AC-A |

### Carried (iteration-2) dispositions still binding

- **seerr pin** — `ghcr.io/seerr-team/seerr@sha256:1b5fc1ea825631d9d165364472663b817a4c58ef6aa1013f58d82c1570d7c866`
  (= `v3.0.1`; registry-verified manifest list, child digests `e2529e89…` amd64,
  `2696abde…` arm64). GHCR `tags/list` publishes container version tags **only up to
  `v3.0.1`** (plus `latest`/`develop`/`sha-*`); **v3.1.0/v3.1.1/v3.2.0 exist as GitHub
  *Releases* but are NOT pushed as image tags** — not deployable by tag or digest.
- **NFS host fix** — `boot.supportedFilesystems = [ "nfs" ]` is the **SOLE** correct
  fix (gates rpcbind + `nfs-utils`-on-PATH + rpc-statd + idmapd per nixpkgs `nfs.nix`).
  A bare `environment.systemPackages = [ pkgs.nfs-utils ]` trips none of it — not equivalent.
- **seerr env** — plain `API_KEY` (load-time seed via `generateApiKey()`); `CONFIG_DIRECTORY`
  sets the settings.json path. No `SEERR__AUTH__APIKEY`, no `TMDB_API_KEY` handler.
- **`__AUTH__APIKEY` seeding** — Sonarr/Radarr CONFIRMED (Radarr #11157, AuthOptions);
  Prowlarr strong-inference. The §6 grep-gate is the verify-don't-assume mechanism.
- **Tdarr node var** — `serverURL` (full URL); `serverIP`+`serverPort` deprecated.
- **dependsOn (PL-3 conclusion)** — `media-storage` `dependsOn` is **empty** (no LB,
  no secrets); `media-core` carries **`dependsOn: [media-storage, metallb-config]`**.
- **Lean-core is STRUCTURAL** — no `media-extras` Flux pointer authored in PR-1.
- **Canary is a declarative `batch/v1` Job** in `00-storage`, gated on `Complete`.
- **`prune: disabled` on BOTH PV and PVC**; PV `claimRef` carries no `uid`.
- **Hard `nodeAffinity NotIn 4gb`** on the heavy pods only; light pods rely on the
  existing `PreferNoSchedule` taint + soft anti-affinity + stack-wide spread.
- **Liveness `failureThreshold:30 periodSeconds:20` (~10 min)** absorbs a realistic
  Akasha cold-boot (3–8 min) under `hard` mount; `D`-state pods can't be force-killed.

---

## 1. Placement & arm64 reality (settled)

The verdict is overwhelmingly **Hyperion**. Every controller in this rollout is a
lightweight .NET/Node/Python/Go service doing pure HTTP API work that never touches a
video frame — textbook Pi-5/arm64 tenants. All write to Akasha media+downloads over a
single NFS mount; the file I/O executes server-side on Akasha's ZFS, so locality is
satisfied by the NFS design (§2), not by moving the app. **The central design decision
is storage, not placement.**

Every service has a real `linux/arm64` manifest **[CONFIRMED]**
(linuxserver/{sonarr,radarr,prowlarr}, ghcr.io/seerr-team/seerr **@ v3.0.1**,
ghcr.io/cleanuparr/cleanuparr, ciuse99/suggestarr, golift/notifiarr, mrcas/kapowarr,
dialmaster/youtarr, ghcr.io/homarr-labs/homarr, nandyalu/trailarr,
ghcr.io/haveagitgat/{tdarr,tdarr_node}). **Tunarr is shelved (decision #4)** — dropped entirely.

| Service | Placement | One-line reason |
|---|---|---|
| Prowlarr | Hyperion | Indexer proxy; pure HTTP, tiny SQLite, clean arm64. No media access. |
| Sonarr | Hyperion | TV PVR; arm64-native .NET, no transcode. Akasha media+downloads via NFS. |
| Radarr | Hyperion | Movie PVR; same profile as Sonarr. |
| seerr | Hyperion | Request UI; Node, API-only, arm64-native. No media-locality pull. |
| Cleanuparr | Hyperion | Queue janitor; .NET, API-only. Hardlink/orphan cleaner OFF/dry-run first. |
| SuggestArr | Hyperion | Recommender glue; tiny Python, API-only. |
| Notifiarr | Hyperion | Go notification relay; API-only. Needs a stable pod hostname. |
| Kapowarr | Hyperion | Comic manager; Python, arm64. Needs `/data` NFS (comic lib + temp on one FS). |
| Youtarr | Hyperion | YouTube grabber; arm64. yt-dlp+ffmpeg remux CPU-bursty but OK. Bundles MariaDB. |
| Homarr | Hyperion | Dashboard; arm64. ~600 MB idle — heavy; hard-excluded from 4 GB nodes. |
| Trailarr | Hyperion | Trailer fetcher; arm64. CPU-only ffmpeg, short clips — cap concurrency. |
| **Tdarr (server)** | Hyperion | Coordinator/UI/DB is light; `internalNode=false`, real arm64 server manifest. |
| **Tdarr (worker)** | **Thoth** | Decision #3 (dual-RTX-6000). arm64 ffmpeg 4.4.2 crippled (#1101) — no Pi worker. |

**Nothing in this rollout is architecture-blocked.** See §8 for Tdarr wiring.

---

## 2. Storage architecture — the central design

### 2.1 One dataset, exported once (highest-leverage rule — [CONFIRMED])

```bash
# ON AKASHA. ONE dataset. Everything below is mkdir, NOT zfs create.
zfs create pool/data                       # the ONE dataset (confirm real pool name — R7/Phase-0 #3)
mkdir -p /mnt/pool/data/torrents/{movies,tv,music,books}
mkdir -p /mnt/pool/data/usenet/{incomplete,complete}
mkdir -p /mnt/pool/data/media/{movies,tv,music,books}
mkdir -p /mnt/pool/data/tdarr-temp         # Tdarr transcode cache (NOT in the hardlink tree — §8/R2)
chown -R 1000:1000 /mnt/pool/data
chmod -R 2775 /mnt/pool/data               # setgid: new dirs inherit gid 1000
```

**Do NOT** `zfs create pool/data/media` / `.../torrents`. An NFS export serves
exactly one dataset and does not traverse children; each child gets a distinct
`fsid`, so cross-tree hardlinks and renames fail `EXDEV`. `crossmnt`/`nohide` exposes
children but does **not** merge fsids (kernel reexport docs: crossmnt children are
exported "with the same options as the parent, **except for fsid**"). **[CONFIRMED]**
This is the single easiest way to silently break the design — and the §2.5 canary Job
is its declarative trip-wire.

### 2.2 Single NFS share (TrueNAS UI → Sharing → NFS)

- **Path:** `/mnt/pool/data` (the ONE export).
- **Mapall User = 1000, Mapall Group = 1000** (Ganesha `Squash=AllSquash` +
  `Anonymous_Uid/Gid=1000`). Mapall, **NOT** Maproot. **[CONFIRMED]** — every
  NFS-written file is owned 1000:1000 on disk regardless of client UID, so the Pi
  PUID and the NFSv4 idmap cross-host problem are non-issues. *(Watch: a forum report
  of "mapall + `mv` rename" edge behavior — covered by the §2.5 canary's rename/link
  check; not a primary refutation.)*
- **Networks:** `192.168.10.0/24`. **Security:** SYS.
- **NFS-only** — do **not** also SMB-share this dataset (mixed-protocol ACL chaos).
- **No second export** of the same tree.

### 2.3 Static NFS PV + PVC (corrected mount options + prune opt-out on BOTH)

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: akasha-data-nfs
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # never let Flux prune the shared PV
spec:
  capacity: { storage: 1Ti }                 # nominal; NFS ignores
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  claimRef: { namespace: media, name: akasha-data }   # NO uid: — lets a recreated PVC rebind
  mountOptions: [nfsvers=4.1, hard, noatime, nconnect=4, rsize=1048576, wsize=1048576]
  nfs: { server: 192.168.10.247, path: /mnt/pool/data }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: akasha-data
  namespace: media
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # protect the PVC too, or rebind breaks
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: akasha-data-nfs
  resources: { requests: { storage: 1Ti } }
```

Mount-option rationale: `nfsvers=4.1` (single port 2049, native locking, `nconnect`);
`hard` (pod blocks-and-resumes on Akasha outage rather than EIO mid-import — `soft`
can corrupt an in-flight import; see R0); `noatime`; `nconnect=4` (standard k8s value).

**Why `prune: disabled` on BOTH:** the PV is `Retain` + `claimRef`-pinned. If
`00-storage` ever renders without the PVC and Flux prunes it, a recreated PVC gets a
new UID — and a `claimRef.uid` on the PV would no longer match, leaving the new PVC
`Pending` and the PV `Released` forever. Protecting the PVC **and** omitting
`claimRef.uid` closes both halves of the foot-gun.

### 2.4 `/config` on local-path is non-negotiable ([CONFIRMED])

Every `/config` / DB volume (incl. seerr `/app/config`, Tdarr
`/app/server`+`/app/configs`+`/app/logs`, **and the Youtarr MariaDB datadir**) **MUST**
be `local-path` RWO. SQLite WAL uses a `-shm` file that is an **mmap'd shared-memory
segment that does not function over NFS** — stronger than the fcntl-lock unreliability;
MariaDB/InnoDB likewise must not run its datadir over NFS. `strategy: Recreate` +
node-pinning is intended.

### 2.5 The make-or-break validation gate — a declarative `batch/v1` Job in `00-storage`

The hardlink/EXDEV/rename canary is **a Job in `00-storage`**, not a manual debug pod,
so Flux `wait:true` health-checks it and **`media-storage` fails before `media-core`
reconciles** if NFS is broken or the child-dataset trap fired. It also proves the
**k3s kubelet** (own mount namespace — k3s #10206) can mount NFS, which a host-shell
`which mount.nfs` cannot.

**Lifecycle (PL-1):** the Job carries **`spec.ttlSecondsAfterFinished: 300`** so it
self-deletes 5 minutes after completing and re-renders clean on every `00-storage`
change. Without it, a re-edited immutable Job spec under a `prune:true/wait:true`
Kustomization would hard-fail `field is immutable` and block `media-storage` forever.
*(Alternative one-shot proof: drop the ttl and run `kubectl delete job
nfs-hardlink-canary -n media` after PR-1 lands. The chosen default is
`ttlSecondsAfterFinished` — it needs no manual follow-up and survives re-edits.)*

**Scope (PL-5):** the canary exercises **both** load-bearing syscalls — the hardlink
(`ln` + matching link-count/inode) **and** the cross-`torrents→media` atomic rename
(`mv`, must not EXDEV). The rename is the actual *arr import syscall the whole design
depends on, distinct from hardlinking; a child-dataset split breaks both, but only the
`mv` check proves the import path itself.

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: nfs-hardlink-canary, namespace: media }
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300        # PL-1: self-delete so re-edits re-render clean (immutable-field guard)
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { topology.kubernetes.io/zone: hyperion }
      containers:
        - name: canary
          image: busybox:1.36
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              mkdir -p /data/torrents/tv /data/media/tv
              echo x > /data/torrents/tv/probe.mkv
              # 1) hardlink across torrents->media (EXDEV here = child-dataset trap)
              ln /data/torrents/tv/probe.mkv /data/media/tv/probe.mkv
              L=$(stat -c '%h' /data/torrents/tv/probe.mkv)
              I1=$(stat -c '%i' /data/torrents/tv/probe.mkv)
              I2=$(stat -c '%i' /data/media/tv/probe.mkv)
              F1=$(stat -f -c '%i' /data/torrents); F2=$(stat -f -c '%i' /data/media)
              echo "links=$L inode1=$I1 inode2=$I2 fsid1=$F1 fsid2=$F2"
              [ "$L" = "2" ] && [ "$I1" = "$I2" ] && [ "$F1" = "$F2" ]
              # 2) PL-5: cross-tree atomic rename — the actual *arr import syscall (must not EXDEV)
              echo y > /data/torrents/tv/probe2.mkv
              mv /data/torrents/tv/probe2.mkv /data/media/tv/probe2.mkv
              [ -f /data/media/tv/probe2.mkv ] && [ ! -f /data/torrents/tv/probe2.mkv ]
              rm -f /data/torrents/tv/probe.mkv /data/media/tv/probe.mkv /data/media/tv/probe2.mkv
          volumeMounts: [{ name: data, mountPath: /data }]
      volumes:
        - { name: data, persistentVolumeClaim: { claimName: akasha-data } }
```

`00-storage`'s kustomization lists this Job; `media-storage` `wait:true` gates on it
reaching **Complete**. `media-core` `dependsOn: media-storage`, so a failed canary
stops the whole stack before any arr pod starts.

### 2.6 qBittorrent repoint (Akasha)

Bind qBittorrent's save path to the **same `/data/torrents/...` string** the *arr pods
see (qBit on Akasha mounts `/mnt/pool/data` → `/data`), running 1000:1000 / umask 002
→ no Remote Path Mapping needed. Fallback if qBit reports an Akasha-native path:
per-arr Remote Path Mapping `192.168.10.247 : /mnt/pool/data/torrents/ →
/data/torrents/` — but the mapping only rewrites the *string*; the pod still needs the
live NFS mount to do the I/O.

---

## 3. Process-user model (one UID/GID, three places) + node-targeting

`1000:1000`, `umask 002` everywhere:

1. **LSIO *arr pods (Sonarr/Radarr/Prowlarr):** `PUID=1000 PGID=1000 UMASK=002` env.
2. **PUID-honoring non-LSIO pods (Kapowarr):** **`PUID=1000 PGID=1000` env** — NOT a
   bare `securityContext.runAsUser` override **[CORRECTED]**. Kapowarr's app files are
   root-owned in the image; default is `PUID=0/PGID=0`. Confirmed at casvt.github.io/Kapowarr.
3. **Native-non-root pods (seerr, Tdarr, SuggestArr):** no PUID — set
   `securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 }`. seerr's
   `node:alpine` `node` user is UID/GID 1000 **[CONFIRMED]**.
4. **Trailarr — verify-first (UNVERIFIED, R-perms):** apply `securityContext 1000`
   **and** check ownership of the first trailer write on `/data`. If root-owned, the
   image ignored the securityContext → switch to its documented lever. Do not assume.
5. **Akasha:** dataset owned 1000:1000 + `mapall=1000:1000` — keep pods at 1000 for
   local-path `/config` ownership consistency.

`fsGroup: 1000` also gids the local-path `/config` volume. **Pre-flight (R8):** confirm
no existing Akasha data is owned by a non-1000 UID (`find /mnt/pool/data ! -uid 1000`);
else a one-time `chown -R 1000:1000` before cutover.

### 3.5 Node-targeting — existing taxonomy, NO new label; hard-exclude only the heavies

**[CONFIRMED in-tree]** the real labels are `topology.kubernetes.io/zone=hyperion`
(all) and `hyperion.lab/memory-tier=4gb` on **beta + gamma only**, each also carrying
`services.k3s.nodeTaint = ["hyperion.lab/memory-tier=4gb:PreferNoSchedule"]`. The 8 GB
nodes are the **unlabeled default**. Any invented `homelab/mem=8gb` label matches
**zero** nodes — do not use it (no new Nix label).

**Two placement levers, applied asymmetrically (fixes the Pending-pod risk):**

- **All media pods** carry `nodeSelector topology.kubernetes.io/zone: hyperion`
  (MANDATORY — control-plane pod-net) + soft `podAntiAffinity` (`stack=media`) +
  participate in a stack-wide **`topologySpreadConstraints maxSkew: 2, topologyKey:
  kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway`** (steers spread without
  ever stranding).
- **The existing `PreferNoSchedule` taint** already softly steers all media off beta+gamma.
- **Hard `nodeAffinity NotIn 4gb`** is applied **only to the heavy pods** — **Homarr**
  (~600 MB idle), **Tdarr server**, **Youtarr (+MariaDB sidecar, ~1.5 GiB pod)**,
  **Sonarr** — for which landing on a 4 GB node is genuinely bad. The light controllers
  (Prowlarr, Radarr, seerr, Cleanuparr, SuggestArr, Notifiarr, Kapowarr, Trailarr) get
  the soft taint only, so under an 8 GB-node crunch (e.g. a rolling `colmena apply`
  cordoning 2-3 nodes) they spill onto a 4 GB node **degraded-but-running** instead of
  `Pending`-forever behind already-PVC-pinned peers.

```yaml
# HEAVY pods (Homarr, Tdarr server, Youtarr, Sonarr) — hard exclude 4 GB:
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: hyperion.lab/memory-tier, operator: NotIn, values: ["4gb"] }
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm: { topologyKey: kubernetes.io/hostname, labelSelector: { matchLabels: { stack: media } } }
# LIGHT pods — omit the nodeAffinity block; keep nodeSelector + soft anti-affinity + the
# stack-wide topologySpreadConstraints. The PreferNoSchedule taint does the soft steer.
```

This honors the IAC-1 "first-class `nodeTaint`/`nodeLabel`, no ExecStart wrapper" rule
— it rides the existing host-file data, adds no Nix change. (Optional future: add
`memory-tier=8gb` to the 8 host files in one commit for positive selection.)

---

## 4. GitOps layout (deliberate divergence from hermes; tightened pinning) + structural lean-core

### 4.1 Convention stance (honest framing)

**[CONFIRMED in-tree]** headlamp + uptime-kuma pin images; **hermes runs
`…/hermes-agent:latest` + a per-app `namespace: hermes`**. So "mirror hermes" is not a
clean authority. This stack makes two **deliberate** choices: one shared `media`
namespace (short cross-DNS for a cooperating stack) and **pin every image** (tightens
hermes's `:latest`). It inherits the verified Flux `Kustomization` shape, the
`decryption.secretRef: sops-age` block, and the `.sops.yaml` `k8s/.*\.sops\.ya?ml$`
rule — **[CONFIRMED]** no `.sops.yaml` change.

### 4.2 ONE-vs-THREE Kustomizations → TWO authored in PR-1, the third deferred

- **Position A (IaC, baseline):** ONE `media` Kustomization; intra-stack ordering is
  post-apply config-wiring.
- **Position B (Old Man):** split on dependency seams; a monolithic `wait:true` over 12
  first-boot-SQLite arm64 pods lets one slow pod fail the whole reconcile.

**Default: the THREE-tier *directory* layout, but PR-1 authors only `media-storage` +
`media-core` Flux pointers.** Blast-radius decides for AC-A. The **lean-core gate is
STRUCTURAL:** `20-extras/` may contain manifests, but with **no `media-extras` Flux
Kustomization in PR-1, Flux physically cannot reconcile it.** Adding that ~8-line
pointer is a **deliberate PR-2 after the ~1-week core soak.**

**Honest framing (PL-6):** this is **single-apply *per tier*** — a deliberate **two-PR
rollout** (lean-core first, then opt-in extras after the soak), NOT a literal one-apply.
The two applies are an intentional design property, not a limitation worked around.

### 4.3 Repo layout

```
Hyperion/k8s/apps/media/
  00-storage/  { namespace.yaml, akasha-data-pv.yaml, akasha-data-pvc.yaml,
                 nfs-hardlink-canary.job.yaml, kustomization.yaml }
                 # NO top-level namespace: in this kustomization (PL-2) — see §4.4
  10-core/     { kustomization.yaml, prowlarr/ sonarr/ radarr/ seerr/,
                 seed-arr-config.sh }        # core-only seeder lives WITH 10-core
  20-extras/   { kustomization.yaml, cleanuparr/ suggestarr/ notifiarr/ kapowarr/
                 youtarr/ homarr/ trailarr/ tdarr/ }     # manifests present; NO Flux pointer in PR-1
```

Each leaf keeps `{deployment, service, config-pvc, secret.sops.yaml}` (secret only
where there is a real secret — §6).

### 4.4 kustomization `namespace:` stamping — intentional divergence (PL-2)

**`00-storage/kustomization.yaml` deliberately sets NO top-level `namespace:` field.**
This is an **intentional divergence** from the hermes pattern this plan otherwise
mirrors. Reason: `00-storage` contains a **cluster-scoped PV** (`akasha-data-nfs`) that
must carry **no** `metadata.namespace`, alongside a Namespace, a PVC, and the canary
Job that each carry `namespace: media` **inline**. A top-level `namespace:` in the
kustomization would make kustomize try to stamp `metadata.namespace` onto the PV,
which is invalid for a cluster-scoped object.

> **Operator note:** copying the hermes `10-core`/`20-extras` kustomizations (which DO
> set a top-level `namespace: media`) into `00-storage` will break it. `00-storage` is
> the deliberate exception because it owns the cluster-scoped PV; `10-core` and
> `20-extras` contain only namespaced objects and keep the top-level `namespace: media`.

### 4.5 Flux Kustomizations (PR-1 authors media-storage + media-core ONLY)

```yaml
# ── PR-1 ──────────────────────────────────────────────────────────────────────
# media-storage  (no LB, no secrets → dependsOn empty; no decryption block — PL-3)
metadata: { name: media-storage, namespace: flux-system }
spec: { interval: 10m, path: ./Hyperion/k8s/apps/media/00-storage, prune: true, wait: true,
        timeout: 5m, sourceRef: {kind: GitRepository, name: flux-system} }
        # wait:true gates on the nfs-hardlink-canary Job reaching Complete (§2.5)
---
# media-core  (LB-bearing + SOPS → BOTH deps + decryption — PL-3)
metadata: { name: media-core, namespace: flux-system }
spec: { interval: 10m, path: ./Hyperion/k8s/apps/media/10-core, prune: true, wait: true,
        timeout: 10m,
        dependsOn: [{name: media-storage}, {name: metallb-config}],   # matches in-tree convention
        sourceRef: {kind: GitRepository, name: flux-system},
        decryption: {provider: sops, secretRef: {name: sops-age}} }

# ── PR-2 (authored ONLY after the ~1-week core soak — structural lean-core) ─────
# media-extras
#   spec: { ..., path: .../20-extras, prune: true, wait: true, timeout: 15m,
#           dependsOn: [{name: media-core}, {name: metallb-config}],
#           decryption: {provider: sops, secretRef: {name: sops-age}} }
```

**dependsOn (PL-3 conclusion):** `media-storage` `dependsOn` is **empty** (no LB, no
secrets — a `metallb-config` dep would be unnecessary). `media-core` carries
**`dependsOn: [media-storage, metallb-config]`**; `media-extras` (PR-2) carries
`[media-core, metallb-config]`.

**SOPS:** each `secret.sops.yaml` mirrors the verified hermes shape — **encrypt only
`data`/`stringData`, metadata plaintext, no comments** (`encrypted_regex:
^(data|stringData)$`) — else kustomize-controller decryption fails. **[CONFIRMED]**

---

## 5. Per-service spec (corrected + verified)

All pods: `nodeSelector { topology.kubernetes.io/zone: hyperion }` + soft
pod-anti-affinity `stack=media` + the stack-wide `topologySpreadConstraints`;
**heavy pods only** add `nodeAffinity NotIn 4gb` (§3.5); `strategy: Recreate`; config on
`local-path`.

| Service | Image (pin) | arm64 | req cpu/mem | lim mem (no cpu lim) | cfg PVC | Port | LB | Key env / secret | Heavy? | Tier |
|---|---|---|---|---|---|---|---|---|---|---|
| Prowlarr | `lscr.io/linuxserver/prowlarr:<pin>` | ✅ | 100m/128Mi | 512Mi | 1Gi | 9696 | .55 | `PROWLARR__AUTH__APIKEY`, PUID/PGID/TZ | no | core |
| Sonarr | `lscr.io/linuxserver/sonarr:<pin>` | ✅ | 100m/256Mi | 1Gi¹ | 5Gi | 8989 | .56 | `SONARR__AUTH__APIKEY`, PUID/PGID/TZ + `/data` | **yes** | core |
| Radarr | `lscr.io/linuxserver/radarr:<pin>` | ✅ | 100m/256Mi | 768Mi | 2Gi | 7878 | .57 | `RADARR__AUTH__APIKEY`, PUID/PGID/TZ + `/data` | no | core |
| **seerr** | `ghcr.io/seerr-team/seerr@sha256:1b5fc1ea825631d9d165364472663b817a4c58ef6aa1013f58d82c1570d7c866`² | ✅ | 100m/128Mi | 512Mi | 2Gi @ **`/app/config`** | 5055 | .54 | **`API_KEY`** only (SOPS); `CONFIG_DIRECTORY=/app/config`; UID 1000; `init: true` recommended | no | core |
| Cleanuparr | `ghcr.io/cleanuparr/cleanuparr:<pin>` | ✅ | 50m/64Mi | 384Mi | 1Gi | 11011 | .61 | arr+qBit keys (SOPS) | no | extras |
| SuggestArr | `ciuse99/suggestarr:v2.8.0`³ | ✅ | 100m/128Mi | 512Mi | 1Gi | 5000 | — | none (SQLite wizard); no PUID | no | extras |
| Notifiarr | `golift/notifiarr:<pin>` | ✅ | 50m/64Mi | 256Mi | 1Gi | 5454 | — | `DN_API_KEY` (SOPS); **`spec.hostname: notifiarr`** | no | extras |
| Kapowarr | `mrcas/kapowarr:v1.3.1` | ✅ | 100m/128Mi | 512Mi | 1Gi | 5656 | .58 | **`PUID=1000 PGID=1000`** + TZ + `/data` | no | extras |
| Youtarr (app) | `dialmaster/youtarr:v1.70.0` | ✅ | 250m/512Mi | 1Gi | 2Gi | 3087 | .59 | `DATA_PATH`, MariaDB host/creds (SOPS) + `/data` | **yes** | extras |
| └ Youtarr MariaDB (sidecar)⁵ | `mariadb:<pin>` (arm64) | ✅ | 100m/256Mi | 512Mi | 2Gi @ datadir (local-path) | 3306 (cluster-internal) | — | root + app pw (SOPS) | **yes** | extras |
| Homarr | `ghcr.io/homarr-labs/homarr:<pin>` | ✅ | 200m/384Mi | 768Mi⁴ | 1Gi | 7575 | .53 | **`SECRET_ENCRYPTION_KEY`** (SOPS, `openssl rand -hex 32`) | **yes** | extras |
| Trailarr | `nandyalu/trailarr:<pin>` | ✅ | 250m/200Mi | 1Gi | 2Gi | 7889 | .62 | securityCtx 1000 **+ verify first write (R-perms)**, TZ + `/data` RW | no | extras |
| Tdarr (server) | `ghcr.io/haveagitgat/tdarr:<pin>` | ✅ | 100m/256Mi | 512Mi | 5Gi @ `/app/server`+`/app/configs`+`/app/logs` | 8265/8266 | .60 | `internalNode=false`, `serverIP=0.0.0.0` + `/data` + **`/temp`→Akasha NFS** | **yes** | extras |

¹ Do **not** cap Sonarr mem tight (OOM-kill history, forum #8180); 1Gi floor.
² **Pin seerr `v3.0.1` by index digest `sha256:1b5fc1ea825631d9d165364472663b817a4c58ef6aa1013f58d82c1570d7c866`**
(registry-verified manifest list: linux/amd64 `e2529e89…` + linux/arm64 `2696abde…`).
**[CONFIRMED this session.]** GHCR `tags/list` publishes container version tags
**only up to `v3.0.1`** (plus `latest`/`develop`/`sha-*`); **v3.1.0/v3.1.1/v3.2.0 exist
as GitHub *Releases* but are NOT pushed as image tags** — not deployable by tag or
digest. Re-pin to a newer digest only when GHCR actually publishes a `v3.1+` version tag
(re-check `tags/list`). **No `TMDB_API_KEY` env** (PR #1250 closed-not-merged) — TMDB key
is set in seerr's settings UI; set `CONFIG_DIRECTORY=/app/config`.
³ Pin **bare `v2.8.0`** (multi-arch list); never the per-arch `v2.8.0-linux-arm64` suffix.
⁴ Homarr idles ~600 MB **[CONFIRMED]** (#3759); heavy-pod (hard `NotIn 4gb`).
`SECRET_ENCRYPTION_KEY` mandatory (container exits without it), stable + in SOPS.
⁵ **Youtarr MariaDB is its OWN container in the pod (PL-4)** with explicit
`requests 100m/256Mi`, `limits 500m/512Mi` so the scheduler sees the real **~1.5 GiB**
pod footprint (app + DB). Memory limits ARE enforced on the Pis
(`cgroup_enable=memory`), so an unbudgeted MariaDB sidecar **OOM-kills** under
InnoDB buffer-pool pressure. The MariaDB **datadir is local-path RWO** (§2.4 — never
NFS); the whole pod is heavy and hard-excluded from 4 GB nodes (§3.5).

**Resource-shaping rule (Pi Expert):** **drop CPU *limits* entirely** (CPU limits
throttle bursty ffmpeg/scan without protecting co-tenants); keep CPU *requests*.
**Memory is the OOM axis on a Pi** — honest memory limits so co-scheduled pods on one
8 GB node stay under ~6 GiB (≈2 GiB for kubelet + NFS page cache).

**Cluster resource-sum check (memory limits, with the PL-4 MariaDB correction):**
sum of memory *limits* = Prowlarr 512 + Sonarr 1024 + Radarr 768 + seerr 512 +
Cleanuparr 384 + SuggestArr 512 + Notifiarr 256 + Kapowarr 512 + **Youtarr app 1024 +
Youtarr MariaDB 512** + Homarr 768 + Trailarr 1024 + Tdarr-server 512 ≈ **8.3 GiB**
across the 8 GB-eligible pool of 8 nodes. With the stack-wide spread + heavy-pod
4 GB-exclusion, no single 8 GB node should carry more than ~2 GiB of media limits
alongside its ~2 GiB kubelet/page-cache reserve. The Youtarr pod alone is now correctly
modeled as **~1.5 GiB** (1024 + 512), not the previously-hidden ~1 GiB.

**Probes (refined; includes the liveness correction):**
- *arr → `httpGet /ping` (200 without API key) **[CONFIRMED]** for liveness+readiness
  on 8989/7878/9696, plus `startupProbe httpGet /ping failureThreshold:30
  periodSeconds:5` (~150 s) for first-boot SQLite migration — NOT `initialDelaySeconds`
  on liveness.
- seerr → readiness `httpGet /api/v1/status`. Tdarr server → `tcpSocket:8265`. Others
  → `tcpSocket` until a `/ping` is confirmed.
- **Liveness math (R0):** set liveness **`failureThreshold:30 periodSeconds:20
  timeoutSeconds:5` (~10 min)** so a realistic Akasha cold-boot + pool-import (3–8 min)
  under `hard` mount does NOT trip a kubelet restart against `D`-state I/O. Readiness
  can flap (de-registers from LB) without killing the pod. See R0 for the planned-reboot
  runbook.

---

## 6. SOPS seeding contract — scoped to what actually works

The baseline's "all downstream wiring known at deploy time" is **true for the three
Servarr apps only.** Corrected contract:

- **Sonarr / Radarr** — `stringData: { SONARR__AUTH__APIKEY: <uuid> }` etc. via
  `envFrom`. **[CONFIRMED]** .NET `AuthOptions` reads `<APP>__AUTH__APIKEY` on a fresh
  `/config` (Radarr #11157). **No `_FILE` variant** — env only.
- **Prowlarr** — same Servarr .NET base; `PROWLARR__AUTH__APIKEY` honored by the same
  `AuthOptions` — **strong-inference, primary-quote-pending**; treated by the grep-gate.
- **Verify-don't-assume gate:** Whisparr #992 (OPEN) is the cautionary *counter*-example
  — `AuthOptions` missing → env silently ignored. (Sonarr #6744 is a *different*
  single-underscore `SONARR_API_KEY` scheme — not ours.) The seed step MUST `grep -i
  apikey /config/config.xml` == the SOPS value per arr; if ignored, fall back to
  reading the generated key.
- **seerr** — `stringData: { API_KEY: <uuid> }` — **plain name, NOT
  `SEERR__AUTH__APIKEY`, NO `TMDB_API_KEY`** **[CONFIRMED this session in
  `server/lib/settings/index.ts`]**: `generateApiKey()` returns `process.env.API_KEY`;
  on load, if set and differing it updates the stored key (a load-time sync, not a
  guaranteed every-boot re-sync — but functionally it seeds and holds). This seeds
  seerr's *own* key (which SuggestArr/Homarr consume); the keys seerr *consumes*
  (Sonarr/Radarr/Jellyfin) + the TMDB key are set in `settings.json` (seed step or by hand).
- **Homarr** — `SECRET_ENCRYPTION_KEY` (mandatory, `openssl rand -hex 32`).
- **Notifiarr** — `DN_API_KEY` (inbound Notifiarr.com key).
- **Youtarr** — MariaDB root + app password (consumed by both the app container and the
  MariaDB sidecar — §5 footnote 5).
- **No SOPS key-seeding** for SuggestArr (SQLite wizard) or inbound-token-only apps.

Net SOPS surface: ~6 secret files, each a copy of the verified hermes shape.

---

## 7. Bring-up order — Phase-0 gate, automatable vs manual, structural lean-core

### 7.0 PHASE 0 — HARD PREREQUISITES (must pass before the first `git push`)

1. **`nfs-utils` on every media-eligible NixOS Pi host [BLOCKING].** **[CONFIRMED
   ABSENT in-tree this session]**: zero hits for
   `nfs-utils|mount.nfs|rpcbind|supportedFilesystems|services.nfs` across
   `Hyperion/nixos/`. kubelet's in-tree NFS mounter needs `mount.nfs` on the host or
   every PV mount fails `mount: unknown filesystem type 'nfs'`. **Fix — the SOLE
   correct form (the systemPackages parenthetical is struck):** add to
   `Hyperion/nixos/modules/hyperion-base.nix`:
   ```nix
   boot.supportedFilesystems = [ "nfs" ];   # gates rpcbind + nfs-utils-on-PATH + rpc-statd + idmapd
   ```
   **[CONFIRMED against nixpkgs `nfs.nix` @ release-25.11 this session]** that the
   `lib.mkIf (boot.supportedFilesystems.nfs or .nfs4)` block enables
   `services.rpcbind.enable=true`, `system.fsPackages=[pkgs.nfs-utils]`, and the
   `rpc-statd`/`idmapd` setup. A bare `environment.systemPackages=[pkgs.nfs-utils]`
   trips **none** of these — **not equivalent.** Then `cd Hyperion/nixos && colmena
   apply --on '@hyperion-*'`. **Fast pre-check** (necessary, not sufficient): `ssh
   hyperion-delta which mount.nfs`. **Sufficient proof** is the §2.5 canary Job — it
   mounts NFS in the *kubelet's* namespace (k3s #10206: host-PATH `mount.nfs` is not
   proof the kubelet can mount). In the closure → survives a `disko-install` reflash.
   Highest-priority action item in the plan.
2. **Akasha (manual, off-cluster):** dataset (§2.1), single NFS export with mapall
   (§2.2), qBittorrent repoint (§2.6); obtain Jellyfin API key + qBittorrent WebUI
   creds (off-cluster; cannot be minted). Run the R8 ownership pre-flight.
3. **Confirm R7** (real TrueNAS pool name) and patch the PV `nfs.path` before committing.

### 7.1 Apply sequence (single-apply per tier; two deliberate PRs — PL-6)

PR-1 push → `media-storage` (gate: **nfs-hardlink-canary Job `Complete`** — proves BOTH
the hardlink AND the cross-tree `mv`; NOT merely "PV Bound") → `media-core` + **run §7.3
`seed-arr-config.sh`** (gate: `/ping` healthy on all four, Prowlarr app-sync, **one real
hardlinked import** — `ls -li` link count 2 on Akasha, not a copy — the MUST-PASS gate)
→ **run the core ~1 week** → **PR-2** authors the `media-extras` Flux pointer (the
structural lean-core gate), opt-in per service.

> This is **single-apply per tier**, by design two applies (lean-core, then extras after
> the soak) — not a literal single push. The `media-extras` pointer is intentionally
> absent from PR-1 so Flux cannot reconcile extras early.

### 7.2 (removed — `seed-arr-config.sh` is no longer labeled "automatable post-apply")

It is an enumerated **manual** step — see §7.3 #6. A `batch/v1` Job-in-`10-core` form was
considered and **rejected** (it couples `media-core` reconcile health to the first-boot
API readiness of four SQLite pods under `wait:true` — fragile; one slow Pi-SQLite
migration would fail the tier). See §10.

### 7.3 Irreducibly manual (enumerate — AC-A minimizes, does not eliminate)

1. Akasha dataset/export/qBit-repoint + off-cluster Jellyfin/qBit creds (Phase 0 #2).
2. Notifiarr.com + Discord cloud-side webhook setup.
3. First-run admin account for seerr + Homarr (no env seeds the admin user; seerr's
   Jellyfin link is an interactive wizard — R4).
4. Tdarr worker stand-up on Thoth (compose unit, off-cluster — §8).
5. Prowlarr indexer *selection* (which trackers — taste, not seedable).
6. **Run `seed-arr-config.sh` from the workstation** against the `10-core` LB IPs
   **after `media-core` is Ready**. Idempotent (GET-before-POST). **Scoped to core
   endpoints ONLY**: Prowlarr→Sonarr/Radarr app+indexer-sync (`POST
   /api/v1/applications`), Sonarr/Radarr root-folder + qBit download-client (`POST
   /api/v3/rootfolder`, `/api/v3/downloadclient`), seerr→Sonarr/Radarr/Jellyfin server
   entries (`POST /api/v1/settings/{radarr,sonarr,jellyfin}` using `API_KEY`). It lives
   with `10-core`, contains **no** extras endpoints, and cannot half-wire extras
   because their LB IPs/Services don't resolve during the core soak.

**Automation is a trap past this line (Old Man, preserved):** Selenium against the
seerr/Sonarr setup wizards is more fragile than the 5–6 one-time clicks. RE-REJECTED (§10).

---

## 8. Tdarr server(Hyperion) + worker(Thoth) wiring (AC-D)

**Placement rationale + cost (in-scope since #3 is locked):** the server is on Hyperion
for **control-plane uniformity** (Thoth is the *single* off-cluster unit, the GPU
worker). **Cost, named:** the server's SQLite DB lives on one Pi's `local-path`, RWO +
`Recreate` → it **cannot auto-migrate**; that Pi's outage takes the Tdarr control plane
down (Akasha data unaffected). The "server on Thoth too" alternative is
named-and-rejected in §10. The server-pod-kill gate below makes the orphaned-worker risk
testable and self-healing (Tdarr nodes retry continuously), so the placement is sound.

- **Server pod (Hyperion):** `internalNode=false`, `serverIP=0.0.0.0`,
  `webUIPort=8265`, `serverPort=8266`. **[CONFIRMED]**. `local-path` for
  `/app/server`+`/app/configs`+`/app/logs` (never NFS). `/media` → shared `/data` NFS.
  **`/temp` → `/mnt/pool/data/tdarr-temp` Akasha NFS** — NOT Pi local-path.
- **LB:** one MetalLB IP `.60` carrying **both** 8265 (UI) + 8266 (server) on one
  LoadBalancer Service (`metallb.io/loadBalancerIPs: 192.168.10.60`). Only 8266 must be
  LAN-reachable; Thoth needs no inbound port.
- **Thoth worker (off-cluster `docker run`/compose — the ONE non-k8s unit):**
  `ghcr.io/haveagitgat/tdarr_node:<pin>`, **`serverURL=http://192.168.10.60:8266`**
  **[CORRECTED — `serverURL` is the current documented var; `serverIP`+`serverPort`
  are deprecated]**, `nodeName=thoth-gpu`, GPU passthrough (`--gpus all` / NVIDIA
  runtime). **Mount Akasha at byte-identical paths to the server:** `/media` (same
  `/data` layout) AND the same `/temp` (`/mnt/pool/data/tdarr-temp`). Path-identity is
  mandatory or jobs reference dead paths.
- **Shared cache, and it IS copy-back [CONFIRMED]:** Tdarr docs — server + node "need
  access to the same media **and transcode cache** paths," AND files "will be
  transcoded into the transcode cache folder and then **copied back** into your source
  library." So `/temp` holds **full transcoded outputs transiently** (drives R2). The
  **L-4 note** (R2): that copy-back across the NFS mount is **not atomic** — an
  interrupted copy-back can leave a partial file in the source library; Tdarr's own
  verify/checksum step is the guard, but a mid-copy Akasha blip is a known torn-write window.
- **Why `/temp` on Akasha, not a Pi:** a Pi 5 has one ~117 MB/s NIC; routing the GPU
  box's transcode scratch through a Pi makes the dual-RTX-6000 worker NIC-bound on a Pi.
- **Bring-up gate:** after the worker registers, **`kubectl delete pod` the Tdarr
  server**; confirm the Thoth worker **re-registers via the `.60` VIP** once the server
  pod reschedules (continuous-retry behavior verified). This is the empirical check that
  the locked server-on-Pi placement self-heals.

---

## 9. Risks & open items (AC-H)

- **R0 — Akasha + `hard` NFS = stack-wide SPOF (NAMED, ACCEPTED; liveness math
  CORRECTED).** Under `hard`, an Akasha reboot/scrub/pool-import blocks every media
  pod's I/O in uninterruptible `D` state until the server returns. A TrueNAS cold boot +
  pool import is routinely **3–8 min** — *longer* than a naive ~2-min liveness
  tolerance. **Corrected:** liveness `failureThreshold:30 periodSeconds:20` (~10 min)
  absorbs a realistic cold boot; pods then self-resume when the mount returns, **no
  rollout**. **L-6 note:** you **cannot force-kill a `D`-state pod** mid-outage — SIGKILL
  is ignored on blocked NFS I/O — so the "self-resume" story holds only for outages
  shorter than the liveness window. **Planned-reboot runbook:** `kubectl scale deploy -n
  media --replicas=0` *before* a planned Akasha reboot, scale up after — a clean planned
  outage instead of a scramble. Accepted as a homelab trade (Jellyfin + qBit + library +
  Tdarr cache already concentrate on Akasha).
- **R1 — `nfs-utils` on NixOS Pi hosts [CONFIRMED ABSENT → Phase-0 gate].** Resolved by
  §7.0 #1 (`boot.supportedFilesystems=["nfs"]`, the sole fix). No longer "unverified."
- **R2 — `/temp` sizing on Akasha [UNVERIFIED] + non-atomic copy-back (L-4).** `/temp`
  holds full transcoded outputs before copy-back (§8); 4K jobs are tens of GB ×
  worker-parallelism. Give `tdarr-temp` a dedicated quota; size with the Akasha owner.
  (A quota'd child dataset is fine here — it is the transcode cache, NOT part of the
  hardlink tree, so the §2.1 single-dataset rule does not apply.) The copy-back is
  non-atomic — see §8 L-4.
- **R3 — `__AUTH__APIKEY` honored-or-not** is the §6 verify-don't-assume grep gate.
  Fallback = read-and-paste.
- **R4 — seerr admin first-run not seedable.** `API_KEY` seeds the *API* key; the admin
  account / Jellyfin link still needs the wizard (§7.3 #3). Verify against v3.0.1's
  `/api/v1/auth` surface at integration.
- **R5 — seerr #2970 is NON-APPLICABLE by construction.** UID 5000 + SELinux permissive
  on AlmaLinux; NixOS Pis run no SELinux and we run native UID 1000. Cited only as the
  reason we run native 1000 + own `/app/config` 1000.
- **R6 — placement spread.** Soft anti-affinity + the stack-wide
  `topologySpreadConstraints maxSkew:2 (ScheduleAnyway)` steer spread without
  stranding; RWO local-path pins each pod after first schedule. Observe placement per
  tier; tighten only if a node packs ≥3 media pods.
- **R7 — TrueNAS pool name [UNVERIFIED].** `/mnt/pool/data` assumed; confirm before
  committing the PV. Phase-0 #3.
- **R8 — existing Akasha data ownership.** §3 pre-flight `find … ! -uid 1000`; one-time
  `chown -R` if needed.
- **R9 — Cleanuparr orphan/hardlink cleaner** does destructive deletes — leave
  OFF/dry-run first; needs `/data` only if that feature is enabled.
- **R10 — Jellyfin connector caveats.** Sonarr/Radarr→Jellyfin via the Emby connector
  has a 404 history; verify library-refresh-on-import, fall back to scheduled scan.
  Youtarr is NFO-passive. Notifiarr Jellyfin support is webhook-passthrough only.
- **R-perms — Trailarr user model [UNVERIFIED].** Apply `securityContext 1000` then
  verify ownership of the first trailer write; if root-owned, switch to the documented lever.
- **R11 — 4 GB-node count.** beta + gamma are 4 GB (`memory-tier=4gb` +
  `PreferNoSchedule`); the 8 GB media-eligible pool is the other 8 nodes.
- **R12 — pin/hygiene.** seerr pinned by **v3.0.1 index digest** (registry-verified);
  all others by explicit version tag, never `:latest`/`:develop`/`:nightly`/SHA-floating.
  Re-pin seerr only when GHCR publishes a `v3.1+` version tag.
- **R13 — Youtarr MariaDB OOM (NEW, PL-4).** With memory limits enforced on the Pis,
  an unbudgeted MariaDB would OOM under buffer-pool pressure. Now modeled as its own
  container with explicit limits (§5 fn5) and the pod hard-excluded from 4 GB nodes.

---

## 10. Re-rejected alternatives

- **Child datasets + `crossmnt`/`nohide`** — RE-REJECTED. Distinct fsid per child →
  cross-tree hardlinks AND renames still `EXDEV`. The §2.5 canary Job (link + `mv`) is
  its trip-wire.
- **Two PVCs / split `/downloads`+`/media`** — RE-REJECTED. Two `st_dev` → copy+delete.
- **Tdarr `/temp` on Pi `local-path`** — RE-REJECTED. Forces all GPU transcode bytes
  (full copy-back outputs) through one Pi GbE NIC.
- **Tdarr SERVER on Thoth too (UI proxied)** — NAMED-AND-REJECTED. Fewer moving parts +
  removes the Pi-pinned-SQLite failure point, but **rejected** to honor decision #3 and
  keep the GPU box the single off-cluster unit. The §8 reconnect gate makes the
  server-on-Pi risk testable, so the rejection now stands on a verified basis.
- **`seed-arr-config.sh` as a `batch/v1` Job in `10-core`** — REJECTED. Couples
  `media-core` reconcile health (under `wait:true`) to the first-boot API readiness of
  four SQLite arr pods on slow arm64 storage; one slow migration fails the whole tier.
  The enumerated-manual §7.3 #6 form is the honest AC-A answer; the script stays
  committed + idempotent for repeatability.
- **`media-extras` Flux pointer in PR-1** — REJECTED. Withholding the pointer makes the
  lean-core gate physical, not advisory (PL-6).
- **PV `prune:disabled` only (PVC unprotected) / pinning `claimRef.uid`** — REJECTED.
  A pruned-then-recreated PVC gets a new UID and can't rebind to a uid-pinned `Retain` PV.
- **Blanket hard `nodeAffinity NotIn 4gb` on all 12 tenants** — REJECTED. Pending-pod
  generator under an 8 GB-node crunch; hard exclusion is heavy-pods-only.
- **Top-level `namespace: media` in `00-storage/kustomization.yaml`** — REJECTED (PL-2).
  Would stamp `metadata.namespace` onto the cluster-scoped PV; `00-storage` is the
  deliberate exception with no top-level `namespace:`.
- **Canary Job without `ttlSecondsAfterFinished` (one-shot, manual delete)** — kept as a
  documented alternative but NOT the default (PL-1). The ttl avoids the immutable-field
  block on re-edit under `prune:true/wait:true` with no manual follow-up.
- **Youtarr MariaDB as an unbudgeted/implicit process** — REJECTED (PL-4). Modeled as
  its own container with explicit resources so the scheduler sees the ~1.5 GiB pod.
- **democratic-csi for the shared library** — RE-REJECTED. Static PV = zero new components.
- **`fallenbagel/jellyseerr` as primary** — RE-REJECTED (decision #5).
- **One monolithic `media` Kustomization** — retained as dissent, not default.
- **Per-app Flux Kustomization (12×)** — RE-REJECTED. Gates manifest-apply, not API-wiring.
- **Selenium/scripted wizard automation** — RE-REJECTED.
- **Helm / bjw-s app-template** — RE-REJECTED. No Helm infra in-repo.
- **`soft` NFS; NFSv3; idmapd-domain alignment instead of mapall** — RE-REJECTED.
  `soft`→torn imports; `mapall` all-squash removes the idmap bug class. Under v4.1 the
  nixpkgs module installs rpcbind **regardless** — harmless; we avoid v3 because v4.1 is
  single-port + native-lock, not to dodge rpcbind.
- **Invented `homelab/mem=8gb` node label** — RE-REJECTED. Matches zero nodes; use the
  existing `hyperion.lab/memory-tier` taxonomy + `PreferNoSchedule` taint + heavy-pod
  `NotIn 4gb` (§3.5). No new Nix label.
- **seerr `:v3.2.0` floating tag / `@sha256:5f1a70ec…` / `v3.1.0`** — RE-REJECTED. None
  present in GHCR `tags/list` this session; digests unverifiable. Pin `v3.0.1@sha256:1b5fc1ea…`.

---

## 11. Acceptance-criteria coverage matrix (A–H)

| AC | Requirement | Where | Remaining gaps |
|---|---|---|---|
| **A** | **Single-apply per tier** (deliberate two-PR rollout: lean-core, then opt-in extras after the ~1-week soak — PL-6); secrets pre-seeded; dependency order; manual steps enumerated/minimized | §4 (2 PR-1 Kustomizations, structural lean-core, dependsOn incl. metallb-config), §6 (SOPS pre-seed), §7 (Phase-0 gate, canary-Job gate, 6 enumerated manual steps) | Irreducible remainder = seerr/Homarr admin wizard (R4). The two applies are intentional, not a limitation. |
| **B** | Per-service: pinned VERIFIED arm64 image, resources, PVC, ports, env/secrets, LB/ClusterIP, /data | §5 + §3 | seerr pinned by **v3.0.1 registry-verified digest**; Youtarr MariaDB now its own budgeted container (PL-4); LSIO/Tdarr/Homarr `<pin>` version tags filled at build (all arm64-confirmed). |
| **C** | Akasha NFS fully documented | §2.1–§2.6 (commands, single-dataset rule, mapall, **canary Job w/ hardlink + atomic-move**, qBit repoint) | R7 (pool name), R8 (ownership) operator-supplied. |
| **D** | Tdarr server(Hyperion)+worker(Thoth) + LAN reachability | §8 (`serverURL` corrected, copy-back, placement cost, reconnect gate) | R2 (`/temp` sizing) deferred to Akasha owner. |
| **E** | seerr-team/seerr used; Tunarr excluded | §0, §1, §5, §10 | Met. |
| **F** | Integration order; hand vs automatable separated | §7 (Phase-0 + 6 enumerated manual incl. seed script; structural lean-core) | Met. |
| **G** | GitOps consistent with Flux+SOPS+MetalLB+nodeSelector | §4 (deliberate-divergence incl. the `00-storage` no-`namespace:` divergence PL-2, metallb-config dependsOn, no `.sops.yaml` change), §3.5 (existing label taxonomy) | Met. |
| **H** | Risks surfaced; nothing load-bearing unverified | §9 (R0–R13 + R-perms) | BLOCKING items are Phase-0 gates (R1 nfs-utils, R7 pool name) + the canary Job; R2/R6/R-perms bounded UNVERIFIEDs with stated checks. |

---

## 12. Effort

**M.** Akasha export + dataset is S. ~12 app dirs + nodeSelector/affinity +
securityContext/PUID + memory trims are mechanical. Genuinely new: the idempotent
core-scoped `seed-arr-config.sh`, the **nfs-hardlink-canary Job** (hardlink + atomic-move
+ self-deleting ttl), the **Youtarr two-container (app + MariaDB) pod budget**, the Tdarr
`/temp`→Akasha export + matching Thoth mounts, the **one-line `nfs-utils` Nix change +
Colmena apply (Phase-0 gate)**, and the Akasha-NFS + Thoth-worker runbook. No new
cluster components, no Helm, no `.sops.yaml` change. The cost is verification discipline
— the §2.5 canary Job, the §7.0 `nfs-utils` preflight + kubelet-mount proof, the §6
`__AUTH__APIKEY` grep gate, and the §3 Trailarr first-write check.
