# Homelab IaC — To Do

## Status (verified live 2026-09-05) — CLUSTER OPERATIONAL ✅

**All 10 NixOS Pi-5 workers (`alpha`..`kappa`, `.101–.110`) plus the Heimdall
control plane are `Ready`** on k3s `v1.34.5+k3s1`, NixOS 25.11, generation 5
(last `switch` 2026-06-05). **GitOps is healthy:** 31 FluxCD Kustomizations, all
`Ready` and reconciled at `main`. **46 LoadBalancer Services** across 31
namespaces. No node reports DiskPressure/MemoryPressure.

The NixOS pivot, the \*arr stack rollout (PR-1 core *and* PR-2 extras), the
Akasha cleanup and the MonolithBot migration are all **done** — the phase-by-phase
plans that used to live in this file have been removed. The per-node procedure is
[`Hyperion/docs/runbooks/turnkey-node-setup.md`](../Hyperion/docs/runbooks/turnkey-node-setup.md).

---

## Active — public access for friends (SSO + Cloudflare)

**Plan:** [`docs/design/public-access-plan.md`](design/public-access-plan.md)
(2026-09-05; supersedes the transport/sequencing parts of `sso-plan.md`).
Seven phases; nothing is internet-reachable until Phase 4, Jellyfin's single
port-forward opens in Phase 6. Phase 0 has the repo changes and the operator
gates (Cloudflare 2FA, rotate the accounts that become reachable, scoped API
token for DDNS). Immich is not exposed (may be retired).

- [x] **Phase 0a — DONE 2026-09-05.** nftables (+389/636, +7443, 443→RFC1918, −25565),
      deploy.sh Authentik gate, pins (authentik 2026.8.1 / cloudflared 2026.8.3),
      blueprints, tunnel map, Caddy ACME email placeholder.
- [ ] Phase 0b — operator gates (Cloudflare 2FA, rotate exposed accounts, DDNS API token)
- [x] **Phase 1 — DONE 2026-09-05.** Authentik live on Heimdall: 5 containers
      healthy, 776 migrations, all 4 custom blueprints `successful`, LDAP outpost
      connected and listening on `:389`/`:636`, OIDC providers for Homarr +
      Nextcloud, `friends-family` group, `testfriend` created.
      **Exit test passed** from a pod on Hyperion: correct password returns the
      user DN; wrong password → `Invalid credentials (49)`; a user outside
      `friends-family` → `Insufficient access (50)`.
      Four real repo bugs found and fixed on the way — see the commits
      93607f0, 7b45dbc, 71fd71e, 3601656.
      **Still to do here:** enrol TOTP on `akadmin` (D-11) — needs a browser at
      `https://auth.lab` and an authenticator app; it is an operator step, and a
      gate for Phase 4 since `auth` becomes internet-facing there.
- [x] **Phase 2 — DONE 2026-09-05** (API-verified; mobile-app check still worth doing).
      LDAP-Auth v23 active on Jellyfin 10.11.11. `testfriend` authenticates
      (HTTP 200, auto-created, non-admin, all folders); wrong password and
      unknown user both 401. Bind account `svc-jellyfin-ldap` needs the
      `search_full_directory` permission via a role — without it the bind
      succeeds but the search returns nothing. `LdapUidAttribute` must be `cn`,
      **not** `uid` (authentik exposes `uid` as a hash).
      Bind password stored as `JELLYFIN_LDAP_BIND_PASSWORD` in
      `Heimdall/secrets/env.sops.env`.
      **Open:** Jellyfin has **29 pre-existing local users** from the old
      password-sync bot. LDAP does not migrate them — they keep local passwords.
      Cutting a person over means creating them in `friends-family` and removing
      their local account, or they end up with two Jellyfin users. Needs a plan.
- [x] **Phase 3 — DONE 2026-09-05 (auth chain).** `testfriend` signs into Seerr
      via "Sign in with Jellyfin" → HTTP 200, Seerr user auto-created with
      REQUEST-only permissions; wrong password → 401; Seerr `admin` remains as
      break-glass. Chain proven: authentik → (LDAP) → Jellyfin → Seerr.
      Seerr's `applicationUrl` and Jellyfin's `externalHostname` deliberately
      left unset — they point at hosts that don't exist until Phases 4 and 6.
      **Still worth doing by hand:** request a title and confirm it reaches
      Radarr/Sonarr (tests service wiring, not auth).
- [ ] Phase 4 — Cloudflare Tunnel: `auth` first, then `seerr`/`homarr`/`cloud`
- [ ] Phase 5 — OIDC: Homarr flip, Nextcloud `user_oidc`
- [ ] Phase 6 — Jellyfin direct: grey-cloud DDNS via Cloudflare, UCG 443→7443, LE cert
- [ ] Phase 7 — monitors, Authentik Postgres backup, pins, user-guide "from outside" section

---

## Open — infrastructure

### Overdue / lapsed gates

- [ ] **Delete the dead Debian/Packer path.** Its **2026-08-15 sunset gate passed
      with no action.** `Hyperion/retired/` was never created and the files are
      still at their original paths: `Hyperion/packer/`, `Hyperion/ansible/`,
      `Hyperion/bootstrap.sh`, `reimage.sh`, `watch-flash.sh`, `publish-image.sh`,
      `flash-identity-usb.sh`, `flash-node.sh`. Nothing on the NixOS path depends
      on them and the stack that served their images is not running. Also retire
      the CI workflows `build-bootstrap-img.yml`, `build-node-img.yml`, and
      `hyperion-sunset-review.yml` (whose cron has already fired for the last time).
- [ ] **Bump the NixOS channel off 25.11.** Its support window has passed. Runbook:
      [`nixos-channel-upgrade.md`](../Hyperion/docs/runbooks/nixos-channel-upgrade.md).
      Nodes have not been `colmena apply`-ed since 2026-06-05.

### Decide: restore or retire

- [ ] **The Hyperion flashing stack on Heimdall is not running.**
      `Heimdall/hyperion/` (nginx image server `:50011`, `ci-deploy`,
      `journal-remote` `:19532`/`:19531`) is tracked in git but its compose
      project has never been brought up on Heimdall. **Consequence today:**
      `systemd-journal-upload` on Heimdall *and* on all 10 Pi workers is in a
      tight restart loop against a dead sink — **17,367 restarts on
      `hyperion-gamma`, 17,370 on `hyperion-eta`, 17,367 on `hyperion-kappa`**
      (measured 2026-09-05; roughly one restart every 30 s since install). It is
      wasted CPU and it buries `systemctl --failed` noise. Either start the stack
      (still useful as a central journal sink even with the Debian image path
      gone) or set `services.journald.upload.enable = false` in
      `Hyperion/nixos/modules/hyperion-base.nix`, `colmena apply`, and delete the
      stack. **Do one or the other — this is the most concrete live fault found
      in the 2026-09-05 sweep.**
- [ ] **Authentik is tracked but not deployed.** No container; not in
      `Heimdall/docker-compose.yml`. But `Heimdall/scripts/deploy.sh` still brings
      it up unconditionally, the Caddyfile still serves `auth.lab`, and
      `docs/design/sso-plan.md` treats it as the SSO layer. Decide, then make
      deploy.sh + Caddyfile + docs agree.
- [ ] **cloudflared is tracked but not deployed.** The real public path is
      ddns-updater (NoIP) + port forwarding. Same decision.

### Cluster hygiene

- [ ] **Add `--disable traefik`** to the k3s server command. k3s's bundled ingress
      is unused but holds `192.168.10.10`. (`--disable servicelb` is already
      applied and, as of 2026-09-05, captured in
      `Heimdall/k3s-control-plane/docker-compose.yml`.)
- [ ] **Resolve `media/orphanarr`.** Hand-applied Deployment
      (`ghcr.io/stevengann/orphanarr:latest`), **scaled to 0 replicas**, holding
      `192.168.10.89` with no endpoints and **no git source**. Commit it under
      `Hyperion/k8s/apps/` or delete it.
- [ ] **Resolve `hermes/alfred-dashboard`.** A LoadBalancer on `192.168.10.11`
      fronting the Hermes pod's `:8646`. It carries `kustomize.toolkit.fluxcd.io/*`
      labels but is **not** in `Hyperion/k8s/apps/hermes/service.yaml`, so Flux
      never prunes it. Separately, the Caddyfile serves an `alfred.lab` site with
      **no A record behind it** — the route is unreachable by name. Commit the
      Service and seed the record, or remove both.
- [ ] **Never run ad-hoc containers on Akasha.** Throwaway `docker run` on the
      TrueNAS box panicked its kernel and crash-rebooted it three times on
      2026-09-05 (`kernel BUG at lib/list_debug.c:29` during Docker veth
      teardown), taking Jellyfin and all NFS exports down. Use a pod on Hyperion
      instead. Full write-up: failure-patterns.md Pattern 6.
- [ ] **Reap 47 dead pods.** `hyperion-eta` had an eviction storm 22–34 days ago
      (≈45 `Evicted` tdarr pods plus `komga`/`youtarr` `Error`/
      `ContainerStatusUnknown`). The current replicas are all healthy (tdarr,
      komga, youtarr each 1/1) — this is stale garbage, not an active fault, but
      it should be cleared and the eviction cause confirmed as addressed by the
      weekly Nix GC added in `30b9111`.
- [ ] **Flux controllers are restarting often** — `helm-controller` 65,
      `notification-controller` 64, `source-watcher` 63, `image-reflector` 61
      restarts. Not currently breaking reconciliation, but worth a look.

### Architecture

- [ ] **Relocate the k3s control plane off Heimdall.** Still the top architectural
      item. The bridge-networked container means metrics-server/`kubectl top` is
      broken and every app needs `nodeSelector topology.kubernetes.io/zone=hyperion`.
      See [ADR-0002](design/adr-0002-containerized-control-plane-networking.md).
- [ ] **Single-export NFS for the \*arr hardlink guarantee.** As built, Akasha
      exports one dataset per media category, so `Downloads` and `TV-Shows`/`Movies`
      are separate filesystems in the pods and imports fall back to
      copy-then-delete (double disk usage, slower, seed diverges from library).
      The design that avoids this is in
      [`Akasha/docs/runbooks/nfs-media-export.md`](../Akasha/docs/runbooks/nfs-media-export.md),
      which now carries a header saying it was never built. Either migrate to the
      single-export model or write an ADR accepting the trade-off.
- [ ] Minor: migrate `kernelboot` → `kernel` bootloader before
      `nixos-raspberrypi` drops it (`Hyperion/nixos/modules/hyperion-pi5.nix`).

---

## Open — data protection

These are the unresolved CRITICAL findings from
[`docs/dr-readiness-2026-07-04.md`](dr-readiness-2026-07-04.md). *(Its HIGH-1
orphan-workload finding and the komga/nextcloud `.82` collision have since been
fixed; ddns-updater has been captured into git.)*

- [ ] **No backup of any k3s stateful PVC.** Every database is node-local
      `local-path` with `reclaimPolicy: Delete`. Decide: DB-dump CronJobs to
      Akasha, or Longhorn. *(Nodes are already staged for Longhorn — `open-iscsi`
      is active and `/mnt/node-storage/longhorn` exists — but no
      `longhorn-system` namespace has been created. See
      [ADR-0003](design/adr-0003-longhorn-deferred.md).)*
- [ ] **Akasha is a single point of failure** with no snapshot schedule or
      off-host replication, and it holds the only existing backups.
      `Media-Storage` is at 78% of 60 TB.
- [ ] **Recover the orphan k8s secrets** that have no git source.
- [ ] **Back up the operator age key off-site.** ✅ **It is NOT lost** — contrary
      to `docs/sops-secret-inventory.md` and
      [`key-backup-and-recovery.md`](runbooks/key-backup-and-recovery.md) (both of
      which now carry correction banners), the private half of `age1u8tfm7s…` is
      on **owner-thinkpad (`192.168.10.230`)** at `~/.config/sops/age/keys.txt`,
      verified decrypting `Hyperion/nixos/secrets/common.yaml` on 2026-09-05. The
      Flux key is beside it as `hyperion-flux.txt`.
      **Do not run the re-key procedure** — it is unnecessary. What *is* needed:
      the key sits on one machine with **no off-site copy**, and `sops`/`age`/
      `colmena` are installed only there, making owner-thinkpad a single point of
      failure for authoring any secret. Follow the "backing up" half of the runbook.
- [ ] `nextcloud/mariadb-secret.yaml` and `mosquitto/secret.yaml` are committed
      as **plaintext**, not SOPS.

---

## Open — hosts

### Thoth (`192.168.10.144`) — OFFLINE

**Powered off pending hardware changes; all resident services suspended** until
it returns. That covers Ollama (`deepseek-r1:70b`), OpenWebUI, ComfyUI, the
GPU Jellyfin at `:8096`, the Tdarr GPU worker, the Beszel agent, and Pterodactyl
Wings. The `thoth.lab` / `ollama.lab` / `openwebui.lab` / `comfyui.lab` DNS
records and Caddy routes still exist and fail.

- [ ] On return: re-verify NVENC (the 595 data-center → 580 production driver
      switch), reconnect the Tdarr worker to the server at `.62:8266`, and
      re-onboard Komodo Periphery.
- [ ] **Space Engineers Pterodactyl server** — blocked and now moot while Thoth
      is down. Prior diagnosis: the install container
      (`ghcr.io/parkervcp/installers:debian`) never starts on Wings — 0 disk
      bytes, 0 console output, state stays `offline`, while Minecraft (using
      `ghcr.io/pterodactyl/*`) works. Suspected image-pull failure on Thoth.
      Wings is also outdated (1.11.13 vs 1.13.0).

### Epsilon (`192.168.0.105`) — Tdarr worker not running

Hostname `WS-EPSILON`, **Ubuntu 26.04** (the docs said Pop!_OS), RTX 4080, on the
main home subnet. It is documented as running a Tdarr GPU transcode worker via
Docker Compose, but **no container runtime is installed on the host**. With Thoth
also down, Tdarr currently has **no GPU workers at all**.

- [ ] Decide whether Epsilon rejoins the transcode fleet, and if so capture its
      config in the repo (it is currently unmanaged).

---

## Open — service configuration

Deployed and reachable, but reportedly never finished being configured:

- [ ] **Listenarr** (`.73`) — add download client + indexer, point at Akasha audiobooks.
- [ ] **Musicseerr** (`.74`) — add Lidarr API key, connect streaming services.
- [ ] **boxarr** (`.75`) — add Radarr API key, configure box-office preferences.
- [ ] **Jellystat** (`.76`) — connect to Jellyfin (Akasha `.247:30013`).
- [ ] **Sortarr** (`.77`) — connect to Sonarr, Radarr, Jellyfin.
- [ ] **ddns-updater** on Heimdall reports **unhealthy**. Public `*.ddns.net`
      names depend on it. Rotate the three NoIP passwords while fixing it.

---

## Open — power

- [ ] **Energy audit — per-service power draw.** The lab draws 500–700 W total;
      killing one broken game server once dropped it ~45 W, so idle/broken
      services matter. Plan: shut down one service at a time, measure the drop
      via the APC AP7900 PDU (`.180`, Telnet CLI, 8 outlets — 1=Monolith,
      2=Compute, 3=Synology) and HA/UPS telemetry, and flag outliers. A targeted
      PDU control module is planned for when the UPS and a 2nd PDU arrive.
      *(Note: with Thoth off, current draw is not representative.)*

---

## Scheduled — re-evaluate Heimdall as flashing-services home

**By 2027-05-21** (12 months after the Akasha→Heimdall migration), OR when the
Akasha-replacement host is in production, decide: (a) re-migrate the Hyperion
flashing services to the new host, or (b) formally adopt Heimdall as the
permanent home and update CLAUDE.md / README / network-layout accordingly.

Source: `dev-hyperion-flashing-to-heimdall` FINAL.md Tier 4.3. The
temporary-posture commitment is what made the migration palatable; this entry
exists so the trigger doesn't silently slip into permanence. If by **2026-11-21**
(the 6-month mark) there is no Akasha-replacement progress, surface the question
early.

> This decision now interacts with the "restore or retire the flashing stack"
> item above — the stack has not actually been running on Heimdall, so option (b)
> would be adopting a home for something that isn't there.

---

## Node storage layout (NixOS)

| Partition | Size | FS | Mount | Purpose |
|-----------|------|----|-------|---------|
| `nvme0n1p1` | 512 MB | FAT32 | `/boot/firmware` | Pi 5 boot firmware (`kernel.img`, `config.txt`) |
| `nvme0n1p2` | 32 GB | ext4 | `/` | Root OS (NixOS generations live here) |
| `nvme0n1p3` | ~220 GB | ext4 | `/mnt/node-storage` | Node-local ephemeral storage (+ staged Longhorn dir) |

Declarative source of truth: `Hyperion/nixos/disko/nvme-layout.nix`. Measured on
`hyperion-alpha` 2026-09-05: `/` 8.3 G used of 32 G (28%), `/nix/store` 3.0 G,
`/boot/firmware` 111 M of 511 M, `/mnt/node-storage` 151 M of 202 G.
