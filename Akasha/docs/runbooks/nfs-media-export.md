# OPERATOR RUNBOOK — NFS media export on Akasha for the Hyperion *arr stack

> **Host:** Akasha (TrueNAS Scale), `192.168.10.247`.
> **Audience:** the operator, following by hand.
> **Companion plan (source of truth):** `docs/design/arr-stack-plan-iter2-revision.md`.
> This runbook is the **Akasha-side** half of that plan; the Hyperion/k8s side
> lives in `Hyperion/k8s/apps/media/` and `Hyperion/docs/`. Where this runbook
> and the plan disagree, the plan wins — file a fix here.
>
> **Two values are DEFERRED to the operator and appear as placeholders:**
> - **`POOL`** — the real ZFS pool name (plan R7). The plan assumes `/mnt/pool/data`;
>   replace `pool` with your actual pool everywhere below **and** in the PV `nfs.path`
>   before committing the k8s manifests.
> - **`1000:1000`** — the shared UID:GID. The plan locks the *consistency requirement*
>   (one UID/GID in three places) and uses `1000:1000` as the working value; confirm it
>   against any pre-existing data (R8 pre-flight, §6 below) before cutover.

---

## 0. The one rule everything else depends on

**One dataset. One NFS export. One `/data` mount inside the pods.**

The *arr apps (Sonarr, Radarr, etc.) do **atomic moves and hardlinks** when they import
a finished download from `torrents/` into `media/`. Those operations are evaluated
**server-side on Akasha's ZFS** — the kernel will only hardlink or rename within a
**single filesystem** (one `st_dev` / one `fsid`). If `torrents/` and `media/` are not
the same filesystem as seen through the mount, the kernel returns **`EXDEV`
(cross-device link)** and the *arr app silently falls back to **copy-then-delete**.

What copy-delete fallback costs you:

- **Double disk usage** — the file exists twice (in `torrents/` and `media/`) for the
  duration, and the hardlink that would have made the imported copy free never happens.
- **Slow** — every import becomes a full byte copy over NFS instead of a metadata-only
  rename.
- **Broken seed-while-imported** — the whole point of hardlinks is that the torrent
  client keeps seeding the original path while the media library points at the same
  inode. With copy-delete the seed file and the library file diverge; deleting one to
  reclaim space breaks the other.

**Exactly what creates two filesystems (and must be avoided):**

1. **Two NFS exports / two PVs / two mounts** — e.g. exporting `torrents` and `media`
   separately, or giving the pods `/downloads` and `/media` as two volumes. Each mount
   is a distinct `st_dev` → `EXDEV`. **One export, mounted once at `/data`.**
2. **Child datasets** — `zfs create POOL/data/torrents` and `zfs create POOL/data/media`.
   An NFS export serves **exactly one dataset and does not traverse its children**; each
   child dataset gets its own `fsid`. `crossmnt` / `nohide` will *expose* the children
   but explicitly **does not merge fsids** (kernel re-export docs: crossmnt children are
   exported "with the same options as the parent, **except for fsid**"). So child
   datasets re-introduce `EXDEV` even through a single export. **`torrents/` and `media/`
   must be plain directories (`mkdir`), not datasets.**

This is the single easiest way to silently break the design. The `nfs-hardlink-canary`
Job (§5) is the automated trip-wire that catches it before any *arr pod starts.

---

## 1. Create the single dataset + subtree (TrueNAS Scale)

### 1.1 The dataset (ONE `zfs create`)

UI: **Datasets** → select your pool → **Add Dataset**. Name it `data`. Keep it a
**Generic**/default dataset; do **not** create nested `torrents`/`media` datasets.

Or from the Akasha shell (replace `pool` with your real `POOL` — R7):

```bash
# ON AKASHA. The ONE dataset. Everything below 'data' is mkdir, NOT zfs create.
zfs create pool/data
```

### 1.2 The TRaSH-style subtree (plain directories — `mkdir`, never `zfs create`)

```bash
# ON AKASHA — plain directories inside the ONE dataset:
mkdir -p /mnt/pool/data/torrents/{movies,tv,music,books}
mkdir -p /mnt/pool/data/usenet/{incomplete,complete}
mkdir -p /mnt/pool/data/media/{movies,tv,music,books}
mkdir -p /mnt/pool/data/tdarr-temp     # Tdarr transcode cache — NOT in the hardlink tree
```

> **`tdarr-temp` exception:** the Tdarr transcode scratch is the *one* place a quota'd
> **child dataset is acceptable** — it holds transient transcode output that is copied
> back into the library, so it is never hardlinked across the `torrents/`↔`media/`
> boundary. If you want a size cap, `zfs create POOL/data/tdarr-temp` with a quota is
> fine. The single-dataset rule applies only to the hardlink tree (`torrents/` + `media/`).

### 1.3 Ownership and permissions

```bash
# ON AKASHA — replace 1000:1000 with your confirmed shared UID:GID (deferred):
chown -R 1000:1000 /mnt/pool/data
chmod -R 2775 /mnt/pool/data           # setgid (2xxx): new dirs inherit gid 1000
```

The setgid bit (`2775`) makes every directory created later inherit group `1000`, which
keeps ownership consistent as the *arr apps create season/movie folders.

---

## 2. Create the single NFS share (TrueNAS Scale)

### 2.1 Add the share

UI: **Shares** → **Unix (NFS) Shares** → **Add**.

| Field | Value |
|---|---|
| **Path** | `/mnt/pool/data` — **the ONE export.** Browse to the `data` dataset. **Do not** add a second share for `torrents` or `media`. |
| **Description** | `hyperion-arr-media` (free text, for your own identification) |
| **Read-Only** | unchecked (the *arr apps and qBittorrent write here) |

### 2.2 Restrict Allowed Hosts to the Hyperion subnet

In the Add dialog, under **Networks and Hosts** → **Allowed Hosts** → **Add**:

- **Networks:** `192.168.10.0` with CIDR mask **`/24`** (i.e. `192.168.10.0/24`).

This limits the export to the single lab VLAN. The Hyperion worker IPs (`.101–.110`)
and Akasha-local qBittorrent all fall inside it.

### 2.3 Mapall (NOT Maproot) — the cross-host UID fix

Open **Advanced Options** in the Add dialog and set:

| Field | Value |
|---|---|
| **Mapall User** | `1000` (your shared UID — deferred) |
| **Mapall Group** | `1000` (your shared GID — deferred) |
| **Maproot User** | leave **empty** |
| **Maproot Group** | leave **empty** |
| **Security** | **SYS** |

**Why Mapall, not Maproot, and why this is load-bearing:** Mapall squashes **every**
client UID to the chosen user (Ganesha `Squash=AllSquash` + `Anonymous_Uid/Gid=1000`),
so **every file written over NFS lands on disk owned `1000:1000` regardless of which UID
the pod ran as**. That makes the cross-host UID-mismatch problem and the whole NFSv4
idmap-domain class of bugs simply not exist. Maproot only squashes the root user and
would leave non-root client UIDs un-mapped — reintroducing the mismatch. **Mapall and
Maproot cannot both be set; Mapall supersedes Maproot.**

> The **exact UID/GID is deferred to the operator** (plan decision: UID/GID deferred).
> The hard requirement is **three-layer consistency** — see §6. Whatever value you pick,
> the same number goes here as Mapall, on the dataset owner (§1.3), and in the pods.

### 2.4 NFSv4.1 — set the service protocol version

The per-share dialog does **not** choose the protocol version; the **NFS service** does.

UI: **System** → **Services** → **NFS** → (pencil/edit). In the NFS service settings:

- Enable **NFSv4** (check it). This makes the server speak NFSv4 (the client requests
  `4.1` via mount option `nfsvers=4.1` on the Hyperion side — §3.2).
- Leave **Require Kerberos for NFSv4** unchecked (we use Security = SYS).

Then ensure the **NFS** service is **Running** and **Start Automatically** is enabled
(toggle in the Services list).

**Why NFSv4.1** (not v3): single port `2049` (no rpcbind/mountd port dance to firewall),
native byte-range locking, and `nconnect` multi-connection support. (Note: the NixOS
client module installs `rpcbind` regardless under either version — it is harmless under
v4.1; we choose v4.1 for the single-port + native-lock properties, not to dodge rpcbind.)

### 2.5 Do NOT also SMB-share this dataset

Serve `data` over **NFS only**. Adding an SMB share of the same tree creates
mixed-protocol ACL chaos that fights the Mapall squash. One protocol, one export.

---

## 3. The Hyperion side (so you can see both ends)

You do **not** run these on Akasha — they live in the Hyperion repo. They are reproduced
here so the operator sees the full client↔server contract. The first one is a **BLOCKING
Phase-0 prerequisite**: the NFS export is useless until the Pi hosts can mount it.

### 3.1 BLOCKING — NFS client support on every Hyperion NixOS host

Add to `Hyperion/nixos/modules/hyperion-base.nix`:

```nix
boot.supportedFilesystems = [ "nfs" ];   # gates rpcbind + nfs-utils-on-PATH + rpc-statd + idmapd
```

Then push it to every worker from the workstation:

```bash
cd Hyperion/nixos && colmena apply --on '@hyperion-*'
```

**This is THE fix, and the bare form is NOT equivalent.** The k3s kubelet uses an
in-tree NFS mounter that needs `mount.nfs` on the host PATH; without it every PV mount
fails with `mount: unknown filesystem type 'nfs'`. The nixpkgs module
(`nixos/modules/tasks/filesystems/nfs.nix`, release-25.11) gates a
`lib.mkIf (boot.supportedFilesystems.nfs or .nfs4)` block that enables
**`services.rpcbind`**, puts **`nfs-utils` on the system fsPackages (mount.nfs on PATH)**,
and wires up **`rpc-statd`** and **`nfs-idmapd`**.

A bare `environment.systemPackages = [ pkgs.nfs-utils ]` trips **none** of that — it
drops the binary in the store but does **not** start rpcbind/statd or put mount.nfs where
the mount helper looks. It is **not** an acceptable substitute. `boot.supportedFilesystems
= [ "nfs" ]` is the **sole** correct form.

As of this writing `hyperion-base.nix` has **no** NFS support (confirmed: zero hits for
`nfs-utils|mount.nfs|rpcbind|supportedFilesystems|services.nfs` across `Hyperion/nixos/`).
This change must land + `colmena apply` **before** the first `git push` that deploys the
media stack. Because it is in the closure, it survives a `disko-install` reflash.

**Fast pre-check (necessary, not sufficient):**

```bash
ssh hyperion-delta which mount.nfs     # must print a /nix/store/.../bin/mount.nfs path
```

**Sufficient proof** is the canary Job in §5 — it mounts NFS inside the **kubelet's own
mount namespace** (k3s #10206), which a host-shell `which mount.nfs` does not exercise.

### 3.2 The static PersistentVolume + PVC (one RWX volume, one `/data`)

Lives in `Hyperion/k8s/apps/media/00-storage/`. Both objects carry
`kustomize.toolkit.fluxcd.io/prune: disabled` so Flux never prunes the shared storage.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: akasha-data-nfs
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # never let Flux prune the shared PV
spec:
  capacity: { storage: 1Ti }                       # nominal; NFS ignores
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  claimRef: { namespace: media, name: akasha-data }  # NO uid: — lets a recreated PVC rebind
  mountOptions: [nfsvers=4.1, hard, noatime, nconnect=4, rsize=1048576, wsize=1048576]
  nfs: { server: 192.168.10.247, path: /mnt/pool/data }   # patch /mnt/pool → your POOL
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

Mount-option rationale:

- **`nfsvers=4.1`** — single port 2049, native locking, `nconnect` support (matches §2.4).
- **`hard`** — on an Akasha outage the pod **blocks and resumes** when the server returns,
  rather than getting `EIO` mid-import. `soft` can corrupt an in-flight import. (Trade-off
  + recovery: §7 and the plan's R0.)
- **`nconnect=4`** — standard multi-connection value for k8s NFS.
- **`noatime`**, `rsize/wsize=1048576` — throughput hygiene.

**Why `prune: disabled` on BOTH:** the PV is `Retain` + `claimRef`-pinned. If `00-storage`
ever renders without the PVC and Flux prunes it, a recreated PVC gets a new UID; a
`claimRef.uid` on the PV would then no longer match, leaving the PVC `Pending` and the PV
`Released` forever. Protecting the PVC **and** omitting `claimRef.uid` closes both halves
of that foot-gun.

---

## 4. Repoint qBittorrent (on Akasha) to the shared path

qBittorrent runs **on Akasha** and mounts the same dataset (`/mnt/pool/data` → `/data`).
Set its **default save path** (and category save paths) so completed downloads land under
the **same string** the *arr pods see:

```
/data/torrents/movies
/data/torrents/tv
...
```

Run qBittorrent as **`1000:1000` with `umask 002`** so files it writes match the dataset
ownership and stay group-writable.

**Why this is the clean option:** when qBittorrent and the *arr pods refer to the file by
the **identical path string** (`/data/torrents/...`), the *arr apps need **no Remote Path
Mapping** at all — Sonarr/Radarr see the completed download exactly where the download
client says it is, on the same filesystem, and the import is a metadata-only hardlink.

**If it's unavoidable** (qBittorrent reports an Akasha-native path like
`/mnt/pool/data/torrents/...` that the pods don't share): add a per-arr **Remote Path
Mapping** in each *arr (Settings → Download Clients → Remote Path Mappings):

```
Host: 192.168.10.247
Remote Path: /mnt/pool/data/torrents/
Local Path:  /data/torrents/
```

This only rewrites the **path string** the *arr uses; the pod still needs the live NFS
mount at `/data` to do the actual hardlink/move I/O. Prefer fixing qBittorrent's save
path so no mapping is needed.

---

## 5. The make-or-break verification — the `nfs-hardlink-canary` Job

This is the **gate** the plan runs in-cluster before any *arr app deploys. It lives in
`00-storage/` and Flux's `media-storage` Kustomization (`wait: true`) blocks on it
reaching **Complete**; `media-core` `dependsOn: media-storage`, so a **red canary stops
the whole stack before a single *arr pod starts.**

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: nfs-hardlink-canary, namespace: media }
spec:
  backoffLimit: 2
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
              ln /data/torrents/tv/probe.mkv /data/media/tv/probe.mkv   # EXDEV here = child-dataset/2-mount trap
              L=$(stat -c '%h' /data/torrents/tv/probe.mkv)
              I1=$(stat -c '%i' /data/torrents/tv/probe.mkv)
              I2=$(stat -c '%i' /data/media/tv/probe.mkv)
              F1=$(stat -f -c '%i' /data/torrents); F2=$(stat -f -c '%i' /data/media)
              echo "links=$L inode1=$I1 inode2=$I2 fsid1=$F1 fsid2=$F2"
              [ "$L" = "2" ] && [ "$I1" = "$I2" ] && [ "$F1" = "$F2" ]   # non-zero exit = FAIL
              rm -f /data/torrents/tv/probe.mkv /data/media/tv/probe.mkv
          volumeMounts: [{ name: data, mountPath: /data }]
      volumes:
        - { name: data, persistentVolumeClaim: { claimName: akasha-data } }
```

**What it asserts (both must hold):**

1. **(a) Hardlink works** — `ln torrents/tv/probe.mkv → media/tv/probe.mkv`, then
   `stat -c '%h'` shows **link count = 2** and `stat -c '%i'` shows the **same inode** for
   both paths.
2. **(b) Cross-dir move succeeds without EXDEV** — the same single-filesystem property
   that lets `mv /data/torrents/tv/probe → /data/media/tv/probe2` work as an atomic rename
   rather than failing `EXDEV`. (The canary proves it via matching `fsid` on both subtrees
   — `F1 == F2`; an `ln` across two filesystems fails immediately with EXDEV, which is the
   same boundary `mv` would hit.)

**How to read it:**

```bash
kubectl -n media get job nfs-hardlink-canary
kubectl -n media logs job/nfs-hardlink-canary
```

- **Success (GREEN — the gate is passed):** Job shows `COMPLETIONS 1/1`; the log line
  reads `links=2 inode1=<N> inode2=<N> fsid1=<F> fsid2=<F>` with **link count 2**,
  **identical inode** numbers, and **identical fsid**. Only now do you proceed to deploy
  the *arr apps (`media-core`).
- **Failure (RED — do NOT deploy):** Job ends `Failed` / non-zero exit. Causes, in order
  of likelihood: the `ln` threw **EXDEV** (child-dataset trap or a two-mount layout — §0),
  the mount never came up (kubelet can't mount NFS → §3.1 not applied, or rpcbind/statd
  not running), or a permission error (Mapall/ownership mismatch — §6). Fix the cause and
  re-run; do not advance the stack on a red canary.

**Manual host-side equivalent (quick check from Akasha or a Pi):**

```bash
# On Akasha (or any host with the mount), inside the export:
cd /mnt/pool/data
echo x > torrents/tv/probe.mkv
ln torrents/tv/probe.mkv media/tv/probe.mkv
ls -li torrents/tv/probe.mkv media/tv/probe.mkv
#   -> the two lines must show the SAME inode number (first column)
#      and a link count of 2 (the number after the permissions)
mv torrents/tv/probe.mkv media/tv/probe2.mkv   # must succeed, no "Invalid cross-device link"
rm -f media/tv/probe.mkv media/tv/probe2.mkv
```

The in-cluster Job is the authoritative gate (it exercises the kubelet mount path); the
`ls -li` host check is for fast spot-checks.

---

## 6. Permissions / UID-GID consistency (values deferred, the rule is not)

**Pick one UID:GID and use it in all three layers.** The number is deferred to the
operator; the **consistency is mandatory** — a mismatch shows up as permission-denied or
as files the next layer can't manage.

The three layers that must agree:

1. **The *arr / app pods** — `PUID`/`PGID` env on LinuxServer images (Sonarr, Radarr,
   Prowlarr) and Kapowarr; `securityContext { runAsUser, runAsGroup, fsGroup }` on the
   native-non-root pods (seerr, Tdarr, SuggestArr). All set to the same `1000`.
2. **qBittorrent** (on Akasha) — runs as the same `1000:1000`, `umask 002` (§4).
3. **Akasha** — the dataset is **owned** `1000:1000` (§1.3) **and** the NFS share's
   **Mapall User/Group = `1000`/`1000`** (§2.3). Mapall is the safety net: even if a pod
   somehow writes as a different UID, Mapall squashes it back to `1000` on disk.

**R8 pre-flight (run before cutover).** If `data` may already hold data from an earlier
life, confirm nothing is owned by a non-`1000` UID, and fix it once if so:

```bash
# ON AKASHA:
find /mnt/pool/data ! -uid 1000 -print | head        # expect: no output
# if it lists anything:
chown -R 1000:1000 /mnt/pool/data
```

---

## 7. Troubleshooting

### "It copies instead of hardlinking" (EXDEV) — the most important failure

Symptom: imports are slow, disk usage roughly doubles, seeding breaks after import; in
*arr logs you see `EXDEV` / "cross-device link" or "could not hardlink, copying instead."

Cause is almost always a **two-filesystem layout** (§0): either **two mounts/PVs/exports**
(`torrents` and `media` arriving as separate volumes) or the **child-dataset trap**
(`zfs create POOL/data/torrents` / `.../media` instead of plain `mkdir`). `crossmnt`/
`nohide` does **not** fix it — children keep distinct fsids.

Confirm with the §5 manual check: if `ls -li` shows **different inodes** or the `ln`
errors with EXDEV, you have two filesystems. Fix: collapse to ONE dataset + ONE export +
ONE `/data` mount; turn any `torrents`/`media` child datasets back into plain directories
(you will need to move data out, destroy the child dataset, `mkdir`, move data back).
Re-run the canary until GREEN.

### Permission denied on write / files owned by the wrong user

Check the three-layer consistency (§6): Mapall User/Group on the share, dataset owner,
and pod PUID/PGID/securityContext must all be the **same** UID:GID. Verify the share
shows **Mapall** set (not Maproot — and never both). Run the R8 `find ! -uid 1000`.
After a Mapall change, remount on the client (the mapping is applied server-side at
write time, but a stale mount can confuse diagnosis — see stale mounts below).

### Stale NFS mounts on a worker

Symptom: a Pi shows `Stale file handle`, or a pod is stuck mounting after the export was
recreated/renamed on Akasha. Stale handles happen when the exported object's identity
changed under a live mount (e.g. dataset destroyed/recreated, fsid changed).

```bash
# On the affected worker:
mount | grep /data                 # see the stale NFS mount
# Easiest clean recovery: cycle the pod so the kubelet re-mounts fresh:
kubectl -n media delete pod <stuck-pod>
# If a host-level mount is wedged:
sudo umount -f -l /var/lib/kubelet/pods/.../volumes/.../akasha-data-nfs   # lazy-force if needed
```

Avoid recreating the dataset/export under a live mount; if you must, scale the stack to
zero first (next item).

### Akasha-reboot recovery (the accepted SPOF trade-off)

The PV mounts with **`hard`** (§3.2). On an Akasha reboot / pool scrub / pool import,
**every media pod's I/O blocks in uninterruptible `D` state** until Akasha returns. A
TrueNAS cold boot + pool import is routinely **3–8 minutes**. Two consequences:

- **You cannot force-kill a `D`-state pod mid-outage.** `SIGKILL` is ignored on blocked
  NFS I/O — `kubectl delete pod --force` will not clear it until the server is back. Do
  not fight it; restore Akasha.
- **Recovery is automatic once Akasha returns:** with `hard`, the blocked I/O **resumes**
  when the mount comes back — pods self-heal with **no rollout** required, provided the
  outage was shorter than the liveness window (the plan tunes liveness
  `failureThreshold:30 periodSeconds:20` ≈ 10 min so a normal cold boot does not trip a
  restart against `D`-state I/O).

**Planned-reboot runbook** — turn a scramble into a clean outage:

```bash
# BEFORE a planned Akasha reboot, from the workstation:
kubectl -n media scale deploy --all --replicas=0
# ... reboot Akasha, wait for the pool to import and the NFS service to be Running ...
# AFTER Akasha is back:
kubectl -n media scale deploy --all --replicas=1   # (or the per-deploy replica counts)
```

This is the documented, **accepted** trade-off: Akasha is a single point of failure for
the media stack (Jellyfin, qBittorrent, the library, and the Tdarr cache already
concentrate there), and `hard` mounts are chosen deliberately over `soft` because `soft`
can corrupt an in-flight import. `hard` + the planned-reboot drill is the safe combination.

---

## 8. Quick checklist (Akasha side)

- [ ] **ONE** dataset `POOL/data` created (no child datasets in the hardlink tree).
- [ ] `torrents/{...}`, `usenet/{...}`, `media/{...}`, `tdarr-temp` created with **`mkdir`**.
- [ ] `chown -R 1000:1000` + `chmod -R 2775` on `/mnt/POOL/data` (UID/GID confirmed).
- [ ] **ONE** NFS share on `/mnt/POOL/data`; **no** second export; **no** SMB share.
- [ ] Allowed Hosts = **Networks `192.168.10.0/24`**; Security = **SYS**.
- [ ] **Mapall** User/Group = `1000`/`1000`; **Maproot** empty.
- [ ] NFS service: **NFSv4** enabled, service **Running** + start-on-boot.
- [ ] qBittorrent save paths repointed to `/data/torrents/...`, runs `1000:1000` umask 002.
- [ ] R8 pre-flight: `find /mnt/POOL/data ! -uid 1000` returns nothing.
- [ ] (Hyperion side, BLOCKING) `boot.supportedFilesystems = [ "nfs" ]` applied via Colmena.
- [ ] `nfs-hardlink-canary` Job is **GREEN** (link count 2, same inode, same fsid) — the gate.

---

## Sources (TrueNAS Scale UI verified)

- [Adding NFS Shares — TrueNAS Documentation Hub](https://www.truenas.com/docs/scale/shares/nfs/addingnfsshares/)
- [Mapall & Maproot explanation — TrueNAS Community](https://www.truenas.com/community/threads/mapall-maproot-better-explanation-please.54877/)
</content>
</invoke>
