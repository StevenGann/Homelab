<!-- Generated 2026-07-04 by an 8-agent repo-vs-live reconciliation audit. Point-in-time; re-run to refresh. -->
# Homelab Disaster-Recovery Readiness Report

*Reconciliation of Git repo `/home/sydney/GitHub/Homelab` against the live homelab, synthesized from 8 dimension audits (k3s workloads, k3s secrets, IP/DNS, Heimdall, Thoth, Hyperion NixOS, storage/data, completeness sweep).*

---

## 1. Executive summary

**Verdict: NO — the homelab cannot be fully rebuilt from the repo today, and worse, key runtime data is not protected by *any* backup system.** The *control-plane intent* is in good shape: the 10-node Hyperion NixOS cluster is 1:1 rebuildable from git (pinned flake + per-node age keys + one bootstrap SD), the Flux-wired majority of k3s workloads (~75%, the media *arr stack, hermes, caldera, pterodactyl, romm, n8n, nextcloud, metallb, etc.) reconciles cleanly, Thoth's 7-service compose matches git, and Heimdall's core 5 containers are byte-identical to git. But a git-only rebuild would silently come back **missing** eight k3s workloads, three live secrets (agent-caldera + two jeeves secrets are unrecoverable), the Heimdall dynamic-DNS service and its NoIP credentials, and the Alfred UI — and it would **fail to decrypt every SOPS secret** because the bootstrap never recreates the Flux `sops-age` key. Most critically, this is layered on top of a **total absence of data backup**: every k3s database is single-replica node-local `local-path` with `reclaimPolicy=Delete` and no replication, and Akasha (the ~6TB TrueNAS media + all Nextcloud files) has no snapshot/replication/config-as-code and no SSH access to even verify. A single Pi NVMe failure or Akasha loss is permanent, undocumented data loss today. The gaps are mostly closable — many are mechanical wiring — but the data-protection and secret-recovery holes are decisions that must be made and executed before this estate can be called DR-ready.

---

## 2. DR-readiness scorecard

| Subsystem | Verdict | One-line reason |
|---|---|---|
| **Hyperion NixOS (10 nodes)** | ✅ Rebuildable | Flake pinned, per-node age keys committed, live matches git 1:1; only out-of-git dependency is the operator age key (by design). |
| **k3s apps / workloads** | ⚠️ Partial | Flux-wired core reconciles, but 8 workloads (6 hand-applied apps, sortarr's CR, beszel-agent DS) vanish on a git-only rebuild. |
| **k3s secrets / config** | ⚠️ Partial | 3 live secrets have no git source (unrecoverable); Flux `sops-age` key never recreated by bootstrap; 3 secrets committed in plaintext. |
| **Heimdall edge stack** | ⚠️ Partial | Core 5 containers byte-identical to git, but ddns-updater + NoIP creds + alfred.html are live-only; Authentik/cloudflared asserted but not running. |
| **Thoth GPU host** | ⚠️ Partial | 6 of 7 services rebuild; BlueMap jar/config outside git; game-server world + wings.db have no backup. |
| **Storage / persistent data** | ❌ Gap | NO backup of any local-path PVC and NO verifiable Akasha snapshot/replication; node or Akasha loss = permanent data loss. |
| **DNS / IP allocation** | ⚠️ Partial | seed-zones.sh is additive-only and drifted; komga/nextcloud both claim .82 (nextcloud stuck pending); 6 live records absent from git. |
| **Sensors / misc stragglers** | ⚠️ Partial | Sensors/ESPHome well-captured (SOPS + firmware in git); but Epsilon, JMP Pi, and Home Assistant consumer are un-captured. |

---

## 3. Critical & High findings

### CRITICAL (5)

#### C1 — Three live k8s secrets have no git source and are permanently unrecoverable
- **What:** `agent-caldera-secrets` (ns agent-caldera, 3 keys), `jeeves-deepseek` (DeepSeek API key), and `jeeves-shared` (2 tokens) exist only in the live cluster. They were created out-of-band; no SOPS manifest, seed script, or doc exists in the repo. jeeves' `kustomization.yaml` even references `deepseek.yaml`/`shared.yaml` that do not exist on disk (so `kustomize build` would fail).
- **Evidence:** `kubectl -n agent-caldera get secret` → agent-caldera-secrets 3 keys, 17d; `kubectl -n jeeves get secret` → jeeves-deepseek(1), jeeves-shared(2), 22d; `find/grep` across repo = 0 creation hits; agent-caldera deployment.yaml L58 `secretRef: agent-caldera-secrets`.
- **DR impact:** On cluster loss, both apps come back crash-looping with no way to reconstruct the API keys/tokens. Losing the cluster loses these secrets forever.
- **Fix:** Extract live keys now; create `Hyperion/k8s/infrastructure/agent-caldera/secret.sops.yaml`, `apps/jeeves/deepseek.sops.yaml`, `apps/jeeves/shared.sops.yaml`; add each to its kustomization and add a `decryption: {provider: sops, secretRef: {name: sops-age}}` block to the Flux Kustomization.

#### C2 — A from-scratch Flux bootstrap cannot decrypt ANY secret (sops-age key not recreated)
- **What:** Every `*.sops.yaml` is encrypted to the operator key + a dedicated Flux cluster age key whose private half lives only in the `flux-system/sops-age` Secret (correctly not in git). But README step 4 (`kubectl apply -k flux-system` → "Flux reconciles everything") never recreates that key. No `age-keygen`, no `kubectl create secret generic sops-age`, no `sops updatekeys` step exists anywhere.
- **Evidence:** README L214-225 and Hyperion/k8s/README L113-114 say "created out-of-band, never in git" with no recreate command; grep for the recreate commands = 0 hits.
- **DR impact:** On a clean rebuild, kustomize-controller fails to decrypt all 17 recoverable SOPS secrets until an operator manually rebuilds this key — and the procedure is undocumented. This gates the *entire* secret DR chain.
- **Fix:** Add a DR runbook step **before** the Flux bootstrap: regenerate the Flux age keypair, `kubectl create secret generic sops-age --from-file=...`, run `sops updatekeys` to re-encrypt all `k8s/*.sops.yaml` to the new recipient, and document where the operator age key (`~/.config/sops/age/keys.txt`) is backed up.

#### C3 — Heimdall's dynamic-DNS service (ddns-updater) and its NoIP credentials exist only on the host in plaintext
- **What:** `heimdall-ddns-updater-1` (`qmcgaw/ddns-updater:v2.10.0`) runs as a 6th container under compose project "heimdall" but is **not** in `Heimdall/docker-compose.yml` (which sha256-matches git and defines only 5 services) and was never committed (`git log -S ddns-updater` empty). Its config — plaintext NoIP username/password for **stevengann.ddns.net, the-elevator.ddns.net, the-monolith.ddns.net** — lives only in untracked `/opt/Homelab/Heimdall/ddns-updater/data/config.json`. This is the *actual* public-DNS mechanism (Caddyfile: `jf.stevengann.com → monolith.ddns.net`). Also currently reported **unhealthy**. *(Flagged by both Heimdall and Completeness auditors.)*
- **DR impact:** A `docker compose up -d --remove-orphans` would delete the container; a from-git rebuild omits it entirely → public DNS for all three domains silently fails to return, and the NoIP credentials (which live nowhere in git/SOPS) are lost.
- **Fix:** Add the ddns-updater service block to `Heimdall/docker-compose.yml`; move its config into a SOPS-encrypted file shipped by `deploy.sh` (mirror the technitium-admin-pw / cloudflared pattern); **rotate the 3 NoIP passwords** since they sat unencrypted on disk; investigate the unhealthy status.

#### C4 — No backup of ANY k3s stateful PVC; every database is node-local with reclaimPolicy=Delete
- **What:** Per ADR-0003 the June-2026 NFS migration was reversed — all ~37 config/DB PVCs are now `local-path` on individual Pi NVMes, each node-pinned, single-replica, `reclaimPolicy=Delete`, **no replication**. No backup CronJob, Velero, or restic exists in git or live (only image-refresh + a probe-job). Affected: jellystat PostgreSQL, pterodactyl MariaDB, nextcloud MariaDB, romm MariaDB, all *arr SQLite, n8n, uptime-kuma, beszel, navidrome, youtarr, kapowarr, speedtest-tracker. The one app-level "backup" (jellystat-backup PVC) is *also* local-path on the same cluster (see H11).
- **DR impact:** A single Pi NVMe failure permanently destroys that node's databases. Git recreates the pod; it starts **empty** — download history, monitoring history, workflow state, user accounts all gone.
- **Fix:** Deploy a committed k8s CronJob doing `pg_dump`/`mysqldump`/`sqlite .backup` + tar of config dirs, rsync'd off-cluster to Akasha Infra-Storage (mirror Heimdall's `backup.sh` pattern) — or accelerate the Longhorn migration ADR-0003 defers. Track as a committed workload, not a runbook.

#### C5 — Akasha is a single point of failure with no backup/replication and destroys the only existing backups on loss
- **What:** All 6 media datasets (movies/tv/music/comics/youtube/downloads, ~6TB) plus all Nextcloud user files (nextcloud mounts `192.168.10.247:/mnt/Media-Storage/NextCloud/data` directly) live on the single Akasha TrueNAS host. No ZFS snapshot policy, replication target, or offsite backup exists in git, and Akasha has no SSH so snapshots can't even be confirmed. Ironically, the *only* backup that exists (Heimdall `backup.sh`) writes **into** Akasha (`/mnt/Media-Storage/Infra-Storage`) — so Akasha loss also destroys the Heimdall CA/DNS/Komodo backups.
- **DR impact:** Akasha loss = total loss of the media library, all Nextcloud files, and the Heimdall backups, with no documented statement that this is acceptable.
- **Fix:** Configure and document (in `Akasha/`) a ZFS snapshot schedule + at minimum a replication/offsite target for the irreplaceable Nextcloud + media datasets. Move the Heimdall backup destination off the host it protects. If media is deemed re-acquirable, record that explicitly in an ADR so it is a decision, not an accident.

### HIGH (12)

#### H1 — Six running apps have git manifests but were never wired into Flux (hand-applied)
`boxarr`, `jeeves`, `jellystat`(+`jellystat-db`), `listenarr`, `monolithbot`, `musicseerr` run live with **no** `kustomize.toolkit.fluxcd.io/name` label; their manifests exist under `Hyperion/k8s/apps/<name>/` but none are referenced in `clusters/hyperion/apps.yaml`. **Impact:** a Flux-driven rebuild silently comes back missing all six. **Fix (mechanical):** add a Flux Kustomization entry per app to `apps.yaml` (dependsOn metallb-config for LB ones). *(jeeves/jellystat/monolithbot also intersect the secret findings C1 and H-jellystat-ghost.)*

#### H2 — sortarr's Flux Kustomization CR exists only live, not in git
sortarr *is* Flux-managed live (label `flux=sortarr`, Applied revision `main@sha1:65ea4d2`), but there is no `sortarr` Kustomization in `apps.yaml` — the CR was hand-applied. **Impact:** a rebuild that applies only `clusters/hyperion/` never creates it; sortarr silently drops despite looking healthy today. **Fix (mechanical):** add the sortarr Kustomization block to `apps.yaml` (path `./Hyperion/k8s/apps/sortarr`, dependsOn metallb-config).

#### H3 — beszel-agent DaemonSet git file is not referenced by any Kustomization
`beszel-agent` DaemonSet runs on every node (ns hermes) with no Flux label; `infrastructure/beszel-agent-daemonset.yaml` exists but grep confirms it is wired into nothing (infrastructure.yaml only wires metallb, metallb-config, mosquitto, agent-caldera). **Impact:** dead file in git AND unmanaged live DS — not recreated on rebuild. **Fix (mechanical):** wire it into a Flux Kustomization (or delete if intentionally hand-managed).

#### H4 — Flux bootstrap depends on the sops-age key which isn't recreated
*(Enabler for C2 — the same root cause; see C2 for full detail and fix. Listed to note that without it, even the 17 fully-recoverable SOPS secrets do not decrypt.)*

#### H5 — nextcloud/mariadb DB passwords committed in PLAINTEXT (not SOPS)
`apps/nextcloud/mariadb-secret.yaml` commits `MYSQL_ROOT_PASSWORD` and `MYSQL_PASSWORD` as cleartext stringData, violating the SOPS convention; the nextcloud Kustomization has no `decryption:` block. **Impact:** recoverable but real DB credentials exposed in git history / to any repo reader. **Fix:** rotate both, re-store as `mariadb-secret.sops.yaml`, add sops decryption, scrub history if feasible. *(Related lower-severity plaintext secrets: `jeeves/dashboard-auth.yaml` base64 [MEDIUM, mechanical], `infrastructure/mosquitto/secret.yaml` hashed [LOW].)*

#### H6 — IP conflict: komga and nextcloud both claim 192.168.10.82 → nextcloud stuck `<pending>` and nextcloud.lab resolves to komga
Both `apps/media/20-extras/komga/service.yaml:7` and `apps/nextcloud/nextcloud-service.yaml:6` request MetalLB `192.168.10.82`. komga (deployed 9d) holds it; nextcloud's LoadBalancer is `<pending>` with no reachable address. `seed-zones.sh:100` and the live Technitium zone both map `nextcloud.lab → .82`, which is actually komga; komga itself has no DNS name. **Impact:** a git-encoded conflict that reproduces on every rebuild — nextcloud gets no address, and every pointer to nextcloud lands on komga. **Fix (needs decision):** reassign nextcloud to a free pool IP (e.g. `192.168.10.87`; free ranges are .12-.49 and .87-.99), commit, confirm EXTERNAL-IP assigned, then fix `nextcloud.lab` DNS (live .82 record must be hand-edited in Technitium — seed-zones is additive-only). Add the missing `komga.lab → .82` record. *(Merged: the IP-conflict and DNS-drift findings.)*

#### H7 — Alfred UI (alfred.html) is routed by the in-git Caddyfile but not committed
The Caddyfile (identical live/git) serves `alfred.lab` from `root * /data` + `try_files /alfred.html`, but the 5951-byte `alfred.html` exists only at `caddy/data/alfred.html` (+ an untracked `www/` duplicate); `git ls-files | grep alfred` is empty. **Impact:** `alfred.lab` 404s after a from-git rebuild. **Fix (mechanical):** commit `alfred.html` (e.g. `Heimdall/caddy/www/`) and have `deploy.sh` place it into `caddy/data`; delete the stray `www/` copy. *(Flagged by Heimdall + Completeness.)*

#### H8 — BlueMap CLI jar and /opt/bluemap config are host-only, not in git or setup.sh
The Thoth `bluemap` service mounts `/opt/bluemap/bluemap-5.17-cli.jar` + `/opt/bluemap/config` (core/webapp/webserver.conf, storages, packs) — none under `/opt/Homelab/Thoth`, none in the repo, and `setup.sh` has zero bluemap references. **Impact:** on rebuild the bind mounts materialize empty → bluemap starts with no jar and no config. **Fix (needs decision):** move BlueMap config under the repo, add a pinned jar-fetch (URL+checksum) step to `setup.sh`.

#### H9 — Wings/pterodactyl game-server data (Minecraft worlds, wings.db) not in git and no backup
`/var/lib/pterodactyl/3ad8a9e9-.../` (the live Minecraft world BlueMap renders), `wings.db`, `states.json`, archives/backups are runtime-generated, irreplaceable, and captured nowhere in the repo. **Impact:** loss of Thoth's `/fast` SSD or boot disk = the world and Wings' server records are gone. **Fix (needs decision):** scheduled restic/zfs-send of `/var/lib/pterodactyl` to Akasha; document it.

#### H10 — Akasha host/pool/dataset/export/TrueNAS config is not captured as code
The NFS PVs hardcode a concrete layout (`/mnt/Media-Storage/Media/*`, mapall 568:568, /24 scope) but the only Akasha artifact in git is `docs/runbooks/nfs-media-export.md` — a generic guide with a **placeholder pool name** ("replace pool with your actual POOL"). No real pool name, dataset tree, per-export options, or TrueNAS config-DB export exists in git, and no SSH to audit. **Impact:** after Akasha loss an operator must re-derive the pool and re-create every dataset/export by hand so paths line up with the committed PVs; TrueNAS users/ACLs/shares are captured nowhere. **Fix (needs decision):** commit the real dataset/export layout + periodically export the TrueNAS config DB into git. *(Merged: Storage rebuild-gap + Completeness Akasha finding. The k8s-side NFS *plumbing* — paths, mount-opts, claimRef rebind — IS fully in git and reconstructible; only the Akasha side and the bytes are missing.)*

#### H11 — jellystat "backup" PVC lives in the same failure domain it protects
`jellystat/pvc-backup.yaml` has no `storageClassName` → defaults to `local-path`, node-local on the same cluster as the `jellystat-db` PostgreSQL PVC it backs up. **Impact:** defends only against logical corruption; a node/NVMe loss takes both primary and "backup" together. It is the closest thing to an app-level backup in the cluster and provides no DR value against the dominant risk. **Fix (needs decision):** point backup-data at off-cluster storage (Akasha Infra-Storage) or add a CronJob shipping the dump off-node.

#### H12 — Authentik SSO is defined + deploy-scripted + documented but is NOT running live
The repo carries a full Authentik stack (`Heimdall/authentik/` compose + 4 blueprints), `deploy.sh` L220-235 *unconditionally* brings it up, CLAUDE.md's network table lists it, and `docs/design/sso-plan.md` treats it as the SSO layer — but `docker ps -a --filter name=authentik` is empty. **Impact:** the repo asserts a deployed SSO provider that isn't running; a from-scratch `deploy.sh` diverges from live (either restores a service that was decommissioned, or the SSO layer is an unaddressed outage). **Fix (needs decision):** decide retire-vs-restore; if retired, remove from deploy.sh + CLAUDE.md + sso-plan. *(Companion: `cloudflared` is likewise tracked + in CLAUDE.md but not running — MEDIUM — and the real public path is the noip DDNS + port-forward of C3.)*

---

## 4. Reconciliation action plan

### Mechanical (safe to auto-apply — pure wiring/commits, no judgment needed)

- [ ] **Wire the 8 orphan workloads into Flux:** add Kustomization entries for boxarr, jeeves, jellystat, listenarr, monolithbot, musicseerr (H1), sortarr (H2), and the beszel-agent DaemonSet (H3) into `apps.yaml`/`infrastructure.yaml`. Manifests already exist. *(Note: jeeves also needs its secrets recovered first — see C1.)*
- [ ] **Commit `alfred.html`** into `Heimdall/caddy/www/` and have `deploy.sh` copy it into `caddy/data`; delete the stray `/opt/Homelab/Heimdall/www/` and `Caddyfile.bak`/`.bak2` (H7).
- [ ] **Add the missing/known DNS records to `seed-zones.sh`** and re-run it: `komga.lab→.82`, `agent-caldera.lab→.85`, and the 6 operator-added live records (`guppi.lab→.52`, `jeeves.lab→.80`, `pihole.lab→.4`, `technitium.lab→.4`, `truenas.lab→.247`, `uptime-kuma.lab→.51`); re-run publishes the already-declared `asf.lab→.86`.
- [ ] **Re-run `Thoth/scripts/deploy.sh`** to push the current git compose (enforces the wings `@sha256` digest pin + `pull_policy: always`); remove the host `docker-compose.yml.bak.*` files.
- [ ] **Fix stale in-repo docs:** update `inventory.yaml` hyperion-iota status `flashed-power-fault`→`nixos`; refresh the retired-USB/nixos-anywhere comments in `flake.nix` + `hyperion-identity.nix`; add a superseded banner to `storage-audit-2026-06-05.md` and correct ADR-0003's "Current State" (jellystat-db/musicseerr-cache are local-path, not NFS); fix the Heimdall compose "Four services" header comment.
- [ ] **Convert the two lower-risk plaintext secrets to SOPS:** `jeeves/dashboard-auth.yaml` (base64) and `infrastructure/mosquitto/secret.yaml` (hashed).

### Needs your decision (data policy, credential rotation, or architecture choice)

- [ ] **DECIDE + EXECUTE the backup strategy for local-path databases (C4)** — DB-dump CronJobs to Akasha vs Longhorn migration. Highest-value single action.
- [ ] **DECIDE + CONFIGURE Akasha protection (C5)** — ZFS snapshot schedule + off-host replication; move Heimdall's backup destination off Akasha; or write an ADR declaring media expendable.
- [ ] **Recover the 3 orphan k8s secrets (C1)** before any cluster loss — extract live keys, commit as SOPS, wire decryption.
- [ ] **Capture ddns-updater (C3)** — add the compose service, SOPS the NoIP config, **rotate the 3 NoIP passwords**, fix the unhealthy status.
- [ ] **Write the SOPS `sops-age` recreate + `sops updatekeys` runbook step and back up the operator age key off-site (C2 + data-loss below).**
- [ ] **Rotate + SOPS the nextcloud/mariadb passwords (H5).**
- [ ] **Resolve the .82 conflict (H6):** pick nextcloud's real IP (e.g. .87), update the Service, then hand-correct the live `nextcloud.lab` Technitium record.
- [ ] **Provision BlueMap (H8) + back up `/var/lib/pterodactyl` (H9); point jellystat backup off-cluster (H11).**
- [ ] **Capture Akasha config-as-code (H10)** — real pool/dataset/export layout + TrueNAS config-DB export.
- [ ] **Reconcile Authentik + cloudflared (H12)** — retire-in-docs or restore; correct CLAUDE.md's network table to describe the live noip-DDNS + port-forward public path.
- [ ] **Decide keep-or-delete for the low-severity orphans:** `alfred-dashboard` Service (labelled `flux=hermes` but no git manifest; also the undocumented `.11` LB), dead dir `apps/media/30-web/`, the stale Akasha "cold-backup" Retain PVs, and reconcile `homeassistant.lab` (git `.4` vs live `.147`).
- [ ] **Address the stragglers:** scrub real user PII (email/discord) from `apps/monolithbot/data/user_registry.json`; add repo coverage/notes for Epsilon (Tdarr worker), the JMP Pi appliance (+ its `192.168.30.0/24` subnet, absent from the network table), and where Home Assistant actually runs.

---

## 5. Data-loss exposure (what is NOT backed up / not in git — permanently lost on failure)

**On a single Pi NVMe failure** — permanently lost, git recreates only empty pods:
- All node-local `local-path` databases and app config: jellystat PostgreSQL, pterodactyl MariaDB, nextcloud MariaDB, romm MariaDB, all *arr SQLite (sonarr/radarr/lidarr/prowlarr), n8n workflow state, uptime-kuma + beszel monitoring history, navidrome, speedtest-tracker, youtarr, kapowarr, caldera vault. No backup CronJob/Velero/restic exists anywhere. jellystat's own "backup" PVC dies with the node.

**On Akasha (TrueNAS) loss** — permanently lost, no snapshot/replication/config exists:
- The entire ~6TB media library (movies/tv/music/comics/youtube/downloads).
- **All Nextcloud user files** (mounted directly from Akasha).
- The Heimdall infra backups (CA/DNS/Komodo) — because `backup.sh` writes *into* Akasha.
- The Akasha pool/dataset/export layout and TrueNAS config DB (users, ACLs, shares) — rebuild would be hand-derived from a placeholder-pool runbook.

**On Thoth disk loss** — permanently lost:
- Minecraft worlds + `wings.db` + Wings server records under `/var/lib/pterodactyl`.
- OpenWebUI users/chats/settings on `/fast` (small, non-reconstructible). *(Ollama models on `/tank` are re-pullable — low impact.)*

**On Heimdall host loss** — permanently lost (nowhere in git):
- The 3 NoIP dynamic-DNS credentials (plaintext on disk only) → public DNS for stevengann/the-elevator/the-monolith `.ddns.net` cannot be reconstructed.
- The `pihole-webpassword` secret (no `.sops`, no generator).

**Single-key catastrophic exposure (cluster + workstation lost together):**
- **The operator age private key** (`~/.config/sops/age/keys.txt`) is the sole recovery root for **all** SOPS secrets across both Hyperion and Heimdall (and to decrypt the per-node `node-keys/*.tar.age`). It is never in git and has **no documented off-host backup**. Its loss renders every encrypted secret in git permanently undecryptable and blocks the entire NixOS rebuild. This must be backed up off-site (password manager / offline media) as the top prerequisite for DR being real.

**Secrets exposed *in* git (recoverable but leaking):** nextcloud/mariadb DB passwords (cleartext), jeeves-dashboard-auth (base64), mosquitto-passwd (hashed), and monolithbot user PII (real email + discord IDs) — all should be rotated / SOPS'd / scrubbed.