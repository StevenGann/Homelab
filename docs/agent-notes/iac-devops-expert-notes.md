---
agent: IaC/DevOps Expert
specialization: Packer, Ansible, FluxCD/GitOps, k3s, MetalLB, GitHub Actions, SOPS+age, Docker Compose
last_compacted_utc: 2026-05-21T15:00:00Z
last_updated_utc:   2026-05-21T15:00:00Z
---

# IaC/DevOps Expert — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Anything that crosses the line between "code in the repo" and "running
on a host." Build systems, CI/CD, GitOps reconciliation, secrets, image
distribution, cluster bring-up, observability of the IaC pipeline itself.

---

## Settled knowledge

### Repo conventions (verified 2026-05-17)

- **One physical host per top-level directory** (`Hyperion/`, `Monolith/`, `Heimdall/`).
- **Static host + containers for dynamic config.** The reference is `Monolith/k3s-control-plane/`: bind-mounted state on host filesystem, services pulled from `ghcr.io/stevengann/homelab-*`, managed via Dockge.
- **CI builds + publishes via path-filtered push to `main`.** Workflow naming pattern: `.github/workflows/build-<name>-img.yml`. Each uses `concurrency.group` to serialize, `docker/build-push-action@v5`, ghcr.io tag `:latest`. See `build-healthcheck-img.yml`, `build-ci-deploy-img.yml`, `build-journal-remote-img.yml`.
- **Deploy mechanism is operator-in-the-loop**, not pure GitOps: Dockge polls registry / operator clicks Update. The compose file is the source of truth, drop it into the stack via SMB or SSH.
- **SOPS + age for secrets.** Repo-root `.sops.yaml` does not exist; `Hyperion/.sops.yaml` is the only one and is narrowly scoped (`k8s/.*secret.*\.yaml`). Public key: `age1hmxzj58j4vlr7w7kffx9k5dvx8kgp4dtq3235vt4lwjxlrp8u53sjkv2cx`. New hosts must add their own `.sops.yaml` with the relevant `path_regex` or extend a top-level one.
- **Healthcheck pattern**: `Monolith/k3s-control-plane/healthcheck/healthcheck.py` exposes `:50012/{,summary,scan}`, decorate functions with `@check(name, category, description)` to extend.
- **journal-remote** runs on `192.168.10.247:19532` (plain HTTP, LAN-only) and accepts `systemd-journal-upload` POST to `/upload`. Hyperion sends to it; Heimdall should too.

### Build → distribute → consume pipeline (Hyperion)

```
git push (main, Hyperion/packer/**)
  → GitHub Actions (Packer + QEMU on ubuntu-latest)
  → GitHub Releases  (tags: node-v<EPOCH>, bootstrap-latest)
       ↓ (polled every 5 min by ci-deploy)
  → /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}/
  → nginx :50011 (LAN-only)
  → Pi nodes: bootstrap.sh updates HYPERION-ID USB cache → flashes NVMe
```

`concurrency: build-images` keeps the two image workflows serialized.

### Secrets policy

- Only required GitHub Actions secret: `NODE_SSH_PUBLIC_KEY`. Everything else uses the auto-provided `GITHUB_TOKEN`.
- Monolith-deploy-key approach (CI SSHes to Monolith) was **abandoned**. Monolith pulls from GitHub Releases via `ci-deploy`.
- Workstation-only age private key at `~/.config/sops/age/keys.txt`. Never committed.

### Versioning

- Node IMG version = Unix epoch integer in `/boot/firmware/node-img.ver`. Bootstrap compares with `-gt`/`-ge`. Keep integer comparison — load-bearing in `bootstrap.sh`.

### Cluster status (per `docs/todo.md`)

- Monolith stack (k3s server + nginx + ci-deploy + healthcheck + journal-remote) implemented.
- Packer images, CI workflows, identity USB tooling, EEPROM tooling, reimage tooling — implemented.
- **Not yet done:** k3s + FluxCD bring-up. MetalLB manifests exist under `Hyperion/k8s/infrastructure/metallb/` but FluxCD reconciliation is not wired. "GitOps reconciles the cluster" is aspirational.

### Observability — Vector + Loki is the live path

Confirmed 2026-05-04 via Grafana docs. Promtail EOL'd 2026-03-02. For new agents we choose Vector (single ARM64-native static binary, journald source, disk-backed buffer) and ship to Monolith. Loki monolithic mode (`-target=all`) sized for ~20 GB/day per Grafana — comfortably covers a 10-Pi + Heimdall load.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-21T15:00:00Z — Compaction + Hyperion-flashing-to-Heimdall Stage 1 kicked off

Compacted the file (notes were 4 days old vs 24h compaction protocol). Most Heimdall-planning observations folded into the proposal artifact for run `20260521T144651Z-dev-hyperion-flashing-to-heimdall`; archived the per-iteration review notes after their pipeline closed.

Web-verified facts (2026-05-21):
- **GHCR images public+accessible**: anonymous-token HEAD against `ghcr.io/stevengann/homelab-{ci-deploy,journal-remote,healthcheck}/manifests/latest` returns HTTP 200 with `application/vnd.docker.distribution.manifest.v2+json`. Tags list for `homelab-ci-deploy` shows ONLY `["latest"]` — there is no SemVer/SHA pin available. This is a real risk to flag for the proposal (and a defendable item: `docker compose pull` resolves `:latest` to a digest at pull time, but a re-pull after a regressed build is silently destructive).
- **nginx:alpine current**: mainline `1.31.0-alpine` / stable `1.30.1-alpine` per Docker Hub. The proposal pins `nginx:1.30.1-alpine` (stable channel; matches Monolith's unpinned `nginx:alpine` while moving in the more-stable direction).
- **Dozzle 9.0** (Jan 2026): real-time Docker log viewer; web UI; reads via the Docker socket; SQL-via-DuckDB+WASM in the browser; pattern-match → webhook. Good for *container* logs but NOT for journald-on-disk logs.
- **systemd-journal-gatewayd**: ships in the same Debian `systemd-journal-remote` package the journal-remote container already installs. Serves HTTP on :19531 with output formats `plain` / `json` / `json-sse`, query params `follow=1` + `KEY=match`, AND a built-in HTML5 browser. This is the keystone for the realtime tool: zero new image; just an EXPOSE+ENTRYPOINT change OR a second container off the same base. No browser-side framework needed — `?follow=1&output=json-sse` is consumable by `curl` and any web page via `EventSource`.
- **Caddy + SSE buffering**: Caddy's `reverse_proxy` partially buffers responses; `flush_interval -1` disables buffering and is required for SSE. Documented in caddyserver.com/docs/caddyfile/directives/reverse_proxy. If we route the gateway through Caddy at `flash.lab`, the directive must include `flush_interval -1`.
- **mongo:7.0 vs mongo:8** (sidebar — Heimdall already pins 7.0; not in scope here).

Decisions baked into the proposal:
- Storage = local bind-mount on Heimdall NVMe at `/opt/Homelab/Heimdall/hyperion-images/`. Backed up by `backup.sh`. Defended against NFS-from-Monolith (inverts the bootstrapping story the user explicitly named "Heimdall is up; use it") and proxy_cache (over-engineered for two assets that change weekly).
- Separate Compose stack at `Heimdall/hyperion/docker-compose.yml`, managed as a second Komodo Stack. Defended against same-stack-with-Heimdall because the lifecycles are unrelated and bouncing Hyperion infra shouldn't restart Caddy/Technitium/Komodo.
- Realtime tool = `systemd-journal-gatewayd` (web UI + JSON-SSE) plus a thin `watch-flash.sh` workstation script that polls each Pi's `:8080/` JSON AND tails the gateway's SSE stream filtered to `_SYSTEMD_UNIT=hyperion-bootstrap.service`. Defended against Dozzle (Dozzle reads container logs via Docker socket — wrong source for Pi-side journald).
- Posture = PERMANENT (i.e., these three services now live on Heimdall; Monolith retains k3s server + healthcheck only). Defended against "temporary" because temporary means two migrations.
- ci-deploy on Heimdall (not Monolith) — same reason as Komodo Core on Heimdall: Heimdall is the bootstrap-of-bootstrap host now.

Stage 1 of `20260517T183851Z-dev-heimdall-tech-stack` started. Intake requires: container GUI, filtering DNS (passthrough + ad-block + custom records), reverse proxy + LB with L4 (Minecraft TCP+UDP, FTP active+passive), single ingress, CI/GitOps story, reconstruction runbook. Constraints: no new orchestrators (Docker Compose + Dockge only), no NIH reinvention, single host SPOF acceptable for v1 if stated. Web search mandatory.

### 2026-05-17T19:30:00Z — Stage 5.1 re-review submitted

Re-reviewed `iter-1/04-revision.md` for CI/CD/SOPS correctness. Architecture and SOPS scaffolding survived; two new MAJOR issues introduced by the revision:

1. **Dependabot false claim.** Revision §C11/§D.3 says `package-ecosystem: docker` on `/Heimdall/caddy/image` will surface `caddy-l4` plugin-version bumps. Verified via dependabot-core docs (DeepWiki, GitHub Docs): the docker updater only respects images referenced in `FROM` statements. The `--with github.com/mholt/caddy-l4@v0.1.1` line is parsed by neither the docker ecosystem nor any Dependabot ecosystem. Plugin bumps will NOT surface as PRs via the revision's mechanism. Recommended fix: add a `gomod` ecosystem entry pointing at a tiny `go.mod` stub under `Heimdall/caddy/image/` listing the plugins as Go deps, OR a scheduled GitHub Actions workflow that queries the `mholt/caddy-l4` releases API and opens an issue on new releases.

2. **`http://heimdall.lab/ca.crt` is not a built-in Caddy feature.** Verified via Caddy admin API docs: `GET /pki/ca/local` returns the CA in JSON, but the admin API binds to `localhost:2019` by default — not LAN-accessible. The "fetch via HTTP" pattern requires either an explicit `handle /ca.crt { ... file_server }` block in the Caddyfile or an on-host curl-to-localhost. Runbook step 9 will fail as written.

Cross-host gap finding (Hyperion ServiceLB): the proposed `--disable=servicelb` fix is unsafe to apply incrementally; correct order is MetalLB-up → server-disable → agent-re-roll. Also flagged that `Hyperion/ansible/k3s-agent.yml:38` guards the install task with `when: not k3s_binary.stat.exists` — so re-running the playbook with new `INSTALL_K3S_EXEC` will silently no-op on already-installed agents. Needs an explicit stop/re-install/start task.

Other concessions taken cleanly: dropped my containerized journal-upload, dropped my Cloudflare DNS plugin bake-in, dropped my vsftpd container, accepted setup.sh over both my freeform runbook and full Ansible.

Vote-shape: trending YAE with the seven items as iter-2 cleanup; would flip NAY if issues #1 and #2 don't get resolved before code lands.

### 2026-05-17T23:15:00Z — Finalize-run Stage 5.1 re-review submitted

For run `20260517T213331Z-dev-heimdall-finalize`, reviewed `iter-1/04-revision.md` against the revision's own deferred-to-implementation items. Two MUST-FIX correctness issues found by WebFetch against upstream:

1. **Komodo v2 onboarding flow in `onboard-periphery.sh` (§D.2) is wrong.** Verified via docs.rs/komodo_client: `CreateServer` takes `{name, config, public_key}` and returns `Resource<ServerConfig, ServerInfo>` — NO `onboarding_key` field in the response. The onboarding key comes from a *separate* `CreateOnboardingKey` write call with fields `{name, expires, private_key, tags, privileged, copy_server, create_builder}`. v2 flow is: mint onboarding key (unattached), Periphery uses it on first connect, server resource is auto-created by that connection. Operator never calls `CreateServer` in this flow. Script needs control-flow rewrite. The TOML field name is confirmed `onboarding_key` (singular string), matching the sed pattern. Login struct is `LoginLocalUser{username, password}` returning `JwtOrTwoFactor`; dual-auth supports `Authorization: Bearer` OR `X-Api-Key + X-Api-Secret`. URL path-from-type convention may put login at `/auth/login/LoginLocalUser` rather than `/auth/local/login` — engineer must verify against live instance.

2. **Technitium API in `seed-zones.sh` (§D.4) uses wrong path + wrong parameter shape.** Verified via raw APIDOCS.md: zone creation is `/api/zones/create?zone=<n>&type=Primary` (NOT `createPrimaryZone`). Records endpoints (`/api/zones/records/get`, `/api/zones/records/add`) have correct paths but use query-string params, not JSON bodies. Auth is `Authorization: Bearer <token>` with a Technitium-issued API token — operator's SOPS needs a `TECHNITIUM_API_TOKEN` slot or the script needs a login step.

Other findings (smaller):
- `KOMODO_INIT_ADMIN_USERNAME`/`_PASSWORD` env-var names verified correct (FC F1 resolved — those exact names are in upstream core.config.toml, with `_FILE` variants supported).
- ServerState enum has exactly three variants: Ok, NotOk, Disabled.
- `:2.2.0` pin should stay (not `:2`); recommended adding a future `poll-komodo-releases.yml` mirroring the caddy-l4 polling pattern.
- `sed` regex in `poll-caddy-l4-releases.yml` is correct for SemVer-pure releases; edge case for `-rc1` suffixes deferred to README note.
- Backup `<DATE>` mechanism unspecified; recommended committing `Heimdall/scripts/backup.sh` with rsync + retention so IaC owns the backup mechanism.
- Cross-host PR ordering (DA C11 / §D.7): intermediate state between steps 1+2 is clean — Heimdall serves only `komodo.lab` + `/ca.crt`, no other dependencies.
- Recommended cheap shellcheck workflow (`Heimdall/**/*.sh`).

Vote-shape: YAE-with-conditions. Conditions are N1 (Komodo script rewrite) + N2 (Technitium endpoints+params fix) must land in implementation. Architecture survives. Conceded my Stage-1 framing of Periphery onboarding ("core_public_keys filled in by Core") was wrong; v2 actually uses TOFU onboarding-key + Periphery-generates-its-own-keypair.

### 2026-05-17T21:50:00Z — Finalize-run Stage 1 proposal submitted; Technitium + Komodo verified versions

For run `20260517T213331Z-dev-heimdall-finalize` (amendment scope: AdGuard→Technitium, Dockge→Komodo, MetalLB removed). Key version + integration findings (all 2026-05-17):

- **Technitium DNS Server** v15.2.0 (2026-05-09) — Docker Hub tags include 15.2.0, 15.1.0, 15.0.1, 15.0.0, 14.3.0…; multi-arch incl. amd64/arm64. Config bind-mount at `/etc/dns` (not `/opt/...`). Env vars (`DNS_SERVER_ADMIN_PASSWORD`, `DNS_SERVER_DOMAIN`, forwarders) **only apply on first start when config file is absent** — verified against upstream `DockerEnvironmentVariables.md`. This means "commit AdGuardHome.yaml-style pre-seeded config in repo" does NOT translate to Technitium; instead seed zones+records via the HTTP API (idempotent bootstrap script). Clustering uses DANE-EE-based auth, configured via UI after both nodes running — no pre-shared cluster token at first-start.

- **Komodo** v2.2.0 (2026-05-07) — `ghcr.io/moghtech/komodo-core:2` + `ghcr.io/moghtech/komodo-periphery:2`. `:latest` deprecated per upstream. v2 GA was 2026-03-24 with PKI/Swarm/UI rework; project shows active release cadence. Mongo (recommended) or FerretDB v2 for DB; SQLite/Postgres-direct support removed in v1.18.0. Periphery installs via `setup-periphery.py` to `/usr/local/bin/periphery` + `/etc/systemd/system/periphery.service` + `/etc/komodo/periphery.config.toml`; auth is Noise-protocol asymmetric keys, NOT shared-secret API tokens. Default port 8120. Stack-level `auto_update` toggle + `KOMODO_RESOURCE_POLL_INTERVAL` (default 1-hr) controls Git-poll behavior; we set polling on but `auto_update=false` to preserve iter-1 C5's operator-in-the-loop while gaining drift visibility. Audit log stored in MongoDB — makes mongo-data backup-critical.

- **MetalLB removal cluster-side** (cross-host PR scope, documented here): server-side `--disable=servicelb` and `--disable=traefik` recommended (one routing surface in Caddyfile, not two). `Hyperion/ansible/k3s-agent.yml:38` `when:` guard is a real foot-gun on re-runs — proposal adds a drift-detect/re-install task pair. Files to delete: 4 YAMLs under `Hyperion/k8s/infrastructure/metallb/`. `.10–.99` range in `Hyperion/docs/network-layout.md` becomes "Reserved" (don't immediately repurpose; cheap to hold).

- **Dependabot mechanism fix (iter-1 known-concern #3):** confirmed `package-ecosystem: docker` only handles `FROM` lines, not `xcaddy --with` or `COPY --from` references (dependabot-core issue #5103). Real mechanism for caddy-l4 plugin bumps: scheduled GHA workflow polling `gh release view -R mholt/caddy-l4 --json tagName`, sed-bumps `Dockerfile` + `docker-compose.yml`, opens PR. Rejected the `gomod` stub alternative as honest-but-deceptive to tooling.

Choice on Komodo Core placement: option (a) Heimdall, not Monolith. Bootstrapping inversion reasoning — Heimdall's container manager must not depend on Monolith. Periphery as systemd binary (not container) so it survives Docker daemon restarts.

### 2026-05-17T18:55:00Z — Stage 1 proposal submitted; current tooling versions (web-verified)

Submitted `01-proposals/iac-devops-expert.md`. Top-line stack: Dockge 1.5.0 + AdGuard Home v0.107.74 + Caddy v2.11.1 with caddy-l4 v0.1.1 + vsftpd container (FTP can't be L4-proxied — PASV requires protocol awareness) + journal-upload sidecar to Monolith. Two new CI workflows (`build-heimdall-caddy-l4-img.yml`, `build-journal-upload-img.yml`); everything else upstream-pinned. Per-host `Heimdall/.sops.yaml` reusing the existing age public key. Operator-in-the-loop via Dockge (same as Monolith) — no GitOps poller.

Key version findings (all 2026-05-17):
- **Dockge** v1.5.0 (2026-03-30), multi-arch, single-maintainer (shared with Uptime Kuma) — bus-factor risk acknowledged; pin not `latest`.
- **AdGuard Home** v0.107.74 (2026-04-16), native DoT/DoH upstream, scheduled blocklist updates (1/12/24/72/168h), `filtering.rewrites` for custom records — wins over Pi-hole on encrypted-upstream and config-as-YAML axes.
- **Caddy** v2.11.1; ACME native (HTTP-01, TLS-ALPN-01, DNS-01); internal CA for non-public hostnames.
- **caddy-l4** v0.1.1 (2026-05-14), still flagged "experimental, expect breaking changes" — the one risk point; pinned by image tag.
- **Traefik** v3.7.1 (2026-05-11) — viable alternative but two config sources and more YAML; rejected.
- **HAProxy** has FTP active/passive recipes — useful to know if Caddy+L4 falls apart for any reason.

Lessons for next iteration: Old Man will likely challenge the custom Caddy build (xcaddy) as adding CI burden and the journal-upload sidecar as duplicative if Docker journald log driver alone suffices on the host (then `systemd-journal-upload` can run on the *host*, not in a container — saving one service). Prepare a defense or partial-accept for both.

---

## Sources

- **Packer arm-image plugin (solo-io)** — https://github.com/solo-io/packer-plugin-arm-image — accessed 2026-05-03 — confidence: community (de facto standard)
- **k3s docs** — https://docs.k3s.io — accessed 2026-05-03 — confidence: official
- **FluxCD docs** — https://fluxcd.io/flux/ — accessed 2026-05-03 — confidence: official
- **MetalLB L2 mode** — https://metallb.universe.tf/configuration/ — accessed 2026-05-03 — confidence: official
- **SOPS** — https://github.com/getsops/sops — accessed 2026-05-03 — confidence: official
- **GitHub Actions concurrency** — https://docs.github.com/en/actions/using-jobs/using-concurrency — accessed 2026-05-03 — confidence: official
- **Vector `journald` source** — https://vector.dev/docs/reference/configuration/sources/journald/ — accessed 2026-05-04 — confidence: official
- **Loki deployment modes** — https://grafana.com/docs/loki/latest/get-started/deployment-modes/ — accessed 2026-05-04 — confidence: official
- **Promtail EOL** — https://grafana.com/docs/loki/latest/send-data/promtail/ — accessed 2026-05-04 — confidence: official
- **Dockge releases** — v1.5.0 (2026-03-30), multi-arch images. https://github.com/louislam/dockge/releases — accessed 2026-05-17 — confidence: official
- **AdGuard Home releases** — v0.107.74 (2026-04-16) latest stable. https://github.com/AdguardTeam/AdGuardHome/releases — accessed 2026-05-17 — confidence: official
- **AdGuard Home Docker Hub** — adguard/adguardhome multi-arch incl. amd64. https://hub.docker.com/r/adguard/adguardhome — accessed 2026-05-17 — confidence: official
- **AdGuard Home blocklist auto-update + dnsrewrite** — intervals 1/12/24/72/168h; `filtering.rewrites` for custom records. https://deepwiki.com/AdguardTeam/AdGuardHome/4.2-filter-lists-and-custom-rules — accessed 2026-05-17 — confidence: secondary (DeepWiki mirrors upstream docs)
- **Caddy releases** — v2.11.1 latest stable. https://github.com/caddyserver/caddy/releases — accessed 2026-05-17 — confidence: official
- **Caddy automatic HTTPS** — HTTP-01, TLS-ALPN-01, DNS-01; internal CA for non-public hostnames. https://caddyserver.com/docs/automatic-https — accessed 2026-05-17 — confidence: official
- **caddy-l4 (Layer 4 plugin)** — v0.1.1 (2026-05-14), still experimental; TCP+UDP with SNI/ALPN matchers. https://github.com/mholt/caddy-l4 — accessed 2026-05-17 — confidence: official
- **caddy-dns/cloudflare** — DNS-01 plugin for Cloudflare. https://github.com/caddy-dns/cloudflare — accessed 2026-05-17 — confidence: official
- **Traefik releases** — v3.7.1 (2026-05-11) latest stable; TCP/UDP entrypoints supported. https://github.com/traefik/traefik/releases — accessed 2026-05-17 — confidence: official
- **HAProxy passive FTP tutorial** — vendor recipe for FTP proxying through HAProxy. https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/passive-ftp/ — accessed 2026-05-17 — confidence: official (HAProxy)
- **Docker journald log driver** — writes container stdout/stderr to systemd journal with CONTAINER_NAME structured field. https://docs.docker.com/engine/logging/drivers/journald/ — accessed 2026-05-17 — confidence: official
- **Komodo (rejected alternative)** — Rust-based Compose manager with native Git deploys. https://komo.do/docs/intro — accessed 2026-05-17 — confidence: official
- **Technitium DNS Server v15 release blog** — https://blog.technitium.com/2026/04/technitium-dns-server-v15-released.html — accessed 2026-05-17 — confidence: official (vendor blog)
- **Technitium Docker env vars** — env vars first-start-only when config file absent. https://github.com/TechnitiumSoftware/DnsServer/blob/master/DockerEnvironmentVariables.md — accessed 2026-05-17 — confidence: official
- **Technitium upstream docker-compose** — config bind-mount at /etc/dns. https://github.com/TechnitiumSoftware/DnsServer/blob/master/docker-compose.yml — accessed 2026-05-17 — confidence: official
- **Technitium clustering** — DANE-EE-based auth, UI-configured post-bringup. https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html — accessed 2026-05-17 — confidence: official
- **Komodo v2.2.0 releases** — current stable. https://github.com/moghtech/komodo/releases — accessed 2026-05-17 — confidence: official
- **Komodo mongo.compose.yaml** — upstream reference compose for Core + Mongo + Periphery. https://github.com/moghtech/komodo/blob/main/compose/mongo.compose.yaml — accessed 2026-05-17 — confidence: official
- **Komodo setup-periphery.py** — systemd binary installer. https://github.com/moghtech/komodo/blob/main/scripts/readme.md — accessed 2026-05-17 — confidence: official
- **Komodo periphery.config.toml defaults** — port 8120, Noise-protocol keys via core_public_keys. https://raw.githubusercontent.com/moghtech/komodo/main/config/periphery.config.toml — accessed 2026-05-17 — confidence: official
- **Komodo connect-servers (auth model)** — Noise protocol asymmetric keys. https://komo.do/docs/setup/connect-servers — accessed 2026-05-17 — confidence: official
- **Komodo compose.env** — KOMODO_INIT_ADMIN_PASSWORD, KOMODO_RESOURCE_POLL_INTERVAL, etc. https://raw.githubusercontent.com/moghtech/komodo/main/compose/compose.env — accessed 2026-05-17 — confidence: official
- **Dependabot docker ecosystem scope** — only FROM lines; not COPY --from, not xcaddy. https://github.com/dependabot/dependabot-core/issues/5103 — accessed 2026-05-17 — confidence: official (upstream issue)
- **systemd-journal-gatewayd(8)** — freedesktop.org manpage; HTTP server for journal events on :19531; output formats plain/json/json-sse; `follow=1` for SSE follow; bundled HTML5 browser; built from same `systemd-journal-remote` Debian package the journal-remote container already installs. https://www.freedesktop.org/software/systemd/man/latest/systemd-journal-gatewayd.service.html — accessed 2026-05-21 — confidence: official
- **Dozzle 9.0** — Jan 2026 release; reads Docker socket; DuckDB+WASM SQL log queries; webhook pattern-match. Wrong source for journald-on-disk Pi logs. https://github.com/amir20/dozzle and https://linuxiac.com/dozzle-9-0-real-time-docker-log-viewer-improves-log-grouping/ — accessed 2026-05-21 — confidence: official + secondary
- **Caddy reverse_proxy flush_interval** — `flush_interval -1` disables response buffering, required for SSE. https://caddyserver.com/docs/caddyfile/directives/reverse_proxy — accessed 2026-05-21 — confidence: official
- **nginx Docker tags** — mainline 1.31.0-alpine, stable 1.30.1-alpine on Docker Hub. https://hub.docker.com/_/nginx/tags — accessed 2026-05-21 — confidence: official
- **GHCR anonymous pull probe** — `https://ghcr.io/token?scope=repository:stevengann/homelab-ci-deploy:pull&service=ghcr.io` issues a token; HEAD on `/v2/.../manifests/latest` returns 200 with a manifest digest. Tag list shows `["latest"]` only — no version pins exist for these images. Probed 2026-05-21. — confidence: empirical

---

## Archive

### 2026-05-04 dbg-nvme-not-flashing — resolved

Four observations from May 4 about `bootstrap.sh` (early-reboot loop on bootstrap medium, `cleanup()` trap killing status server too early, empty `node-image/` cache from `flash-identity-usb.sh`, `poll.sh` prune-ordering race) were filed against the `dbg-nvme-not-flashing` pipeline run. Repo commits since (`ee41010 fix: write node-img.ver to NVMe p1 after successful repartition`, plus subsequent merges) indicate the bootstrap path has been updated. Code re-verified 2026-05-17: `MAX_BOOT_ATTEMPTS=3` still present at line 39, status-server start at line 268, version-stamp write at line 532. The specific symptoms documented have either been addressed by the fixes or have not recurred; observations dropped from active to keep the file focused. If they resurface in a future run, file fresh entries.
