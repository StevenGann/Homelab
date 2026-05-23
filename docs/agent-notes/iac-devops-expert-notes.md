---
agent: IaC/DevOps Expert
specialization: Packer, Ansible, FluxCD/GitOps, k3s, MetalLB, GitHub Actions, SOPS+age, Docker Compose
last_compacted_utc: 2026-05-21T15:00:00Z
last_updated_utc:   2026-05-23T06:30:00Z
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

### Repo conventions (verified 2026-05-17, re-checked 2026-05-23)

- **One physical host per top-level directory** (`Hyperion/`, `Monolith/`, `Heimdall/`).
- **Static host + containers for dynamic config.** The reference is `Monolith/k3s-control-plane/`: bind-mounted state on host filesystem, services pulled from `ghcr.io/stevengann/homelab-*`, managed via Dockge.
- **CI builds + publishes via path-filtered push to `main`.** Workflow naming pattern: `.github/workflows/build-<name>-img.yml`. Each uses `concurrency.group` to serialize, `docker/build-push-action@v5` for containers (or the Packer + QEMU action chain for raw Pi images), ghcr.io tag `:latest`. See `build-healthcheck-img.yml`, `build-ci-deploy.yml`, `build-journal-remote-img.yml`, `build-node-img.yml`, `build-bootstrap-img.yml`.
- **Deploy mechanism is operator-in-the-loop**, not pure GitOps: Dockge polls registry / operator clicks Update. The compose file is the source of truth, drop it into the stack via SMB or SSH.
- **SOPS + age for secrets.** Repo-root `.sops.yaml` does not exist; `Hyperion/.sops.yaml` is the only one and is narrowly scoped (`k8s/.*secret.*\.yaml`). Public key: `age1hmxzj58j4vlr7w7kffx9k5dvx8kgp4dtq3235vt4lwjxlrp8u53sjkv2cx`. New hosts must add their own `.sops.yaml` with the relevant `path_regex` or extend a top-level one.
- **Healthcheck pattern**: `Monolith/k3s-control-plane/healthcheck/healthcheck.py` exposes `:50012/{,summary,scan}`, decorate functions with `@check(name, category, description)` to extend.
- **journal-remote** runs on `192.168.10.247:19532` (plain HTTP, LAN-only) and accepts `systemd-journal-upload` POST to `/upload`. Hyperion sends to it from BOTH Bootstrap and Node IMGs (Packer §15).

### Build → distribute → consume pipeline (Hyperion, current)

```
git push (main, Hyperion/packer/**)
  → GitHub Actions (Packer + QEMU on ubuntu-latest, ~120 min wall-clock cap)
  → GitHub Releases  (tags: node-v<EPOCH>, bootstrap-latest)
       ↓ (polled every 5 min by ci-deploy)
  → /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}/
  → nginx :50011 (LAN-only)
  → Pi nodes: bootstrap.sh updates HYPERION-ID USB cache → flashes NVMe
```

`concurrency: build-images` keeps the two image workflows serialized.

### Identity USB schema (current, exFAT)

`flash-identity-usb.sh` writes to a GPT-labelled exFAT partition (label `HYPERION-ID`):
- `/hostname` — single-line text, `hyperion-<greek>`
- `/node-image/` — directory, populated by Bootstrap on first run with the cached `.img` + a `version` file (Unix-epoch integer)

The exFAT choice was deliberate (4 GB+ files for the uncompressed image). Mount-on-Linux requires `exfatprogs`. NVMe identity application is done by `apply-identity.service` (`Hyperion/packer/files/apply-identity.sh`) which reads `/hostname` from the USB and runs `hostnamectl set-hostname` once (guarded by `/etc/hyperion-identity-applied`).

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

### NixOS-on-Pi5 state (verified 2026-05-23 — relevant to this run)

- **Mainline nixpkgs / nixos-hardware Pi 5 support is incomplete.** The official wiki labels Pi 5 "not officially supported" and points readers at the older Pi 4 for "critical projects." Source: https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_5 (accessed 2026-05-23).
- **The production-ready path is the `nvmd/nixos-raspberrypi` community flake.** Vendor-kernel (`linuxPackages_rpi5`) + Raspberry firmware blobs + RPi5 generational bootloader. Latest release `v1.20260517.0` (six days before this run), ~500 commits on develop, 543 stars. Provides its own Cachix substituter `https://nixos-raspberrypi.cachix.org` so kernel + firmware don't need local rebuild. Source: https://github.com/nvmd/nixos-raspberrypi (accessed 2026-05-23).
- **GitHub Actions has free linux-arm64 runners on public repos** since **2025-08-07** (GA). Labels: `ubuntu-24.04-arm`, `ubuntu-22.04-arm`. 4 vCPU. No QEMU emulation needed. Source: https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/ (accessed 2026-05-23).
- **`nixos-anywhere` on aarch64** requires a custom kexec image — the "x86_64 only" default doesn't apply to Pi 5. Workaround: pass `--kexec <aarch64-image>`. Bootstrap-from-USB is the cleaner pattern for Pi 5 (skip kexec entirely). Latest release `1.13.0` (2025-11-13). Source: https://github.com/nix-community/nixos-anywhere (accessed 2026-05-23).
- **sops-nix decrypts at NixOS activation phase**, *after* the bootloader installs. Means: secrets ARE available for k3s tokens (systemd services see them at `/run/secrets/*`), but NOT available in initrd. `neededForUsers = true` writes to `/run/secrets-for-users` before user creation. There is no first-class "secret comes from a USB drive" pattern; the standard route is `sops.age.keyFile = "/path/to/key.txt"` pointing at a key on persistent storage. A USB-mounted key file works as long as the mount happens before activation. Source: https://github.com/Mic92/sops-nix (accessed 2026-05-23).
- **Colmena is the de facto remote-deploy tool** for Pi clusters running NixOS (Rust, stateless, parallel, sops-nix-aware, secrets uploaded out-of-band so they never enter the Nix store). Alternative `deploy-rs` adds automatic rollback on activation failure but is heavier. Plain `nixos-rebuild --target-host` works for one-shot but lacks the per-host metaprogramming Colmena's `hive.nix` provides. Source: https://github.com/zhaofengli/colmena (accessed 2026-05-23).
- **k3s NixOS module (`services.k3s`)** is mainline, mature, 44 options. Token via `tokenFile`, server URL, role (agent/server), `extraFlags`, manifests. Cluster-init/HA supported. Source: https://nixos.wiki/wiki/K3s (accessed 2026-05-23).
- **Impermanence / tmpfs-as-root** is a stable NixOS pattern. Not a fit for the Hyperion use case (NVMe is large; the win would be marginal) but worth knowing as an option.

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

### 2026-05-23T05:01:33Z — Stage 1 proposal for nixos-identity-usb pivot

Submitted `01-proposals/iac-devops-expert.md` for run `20260523T050133Z-dev-nixos-identity-usb`. Headline architectural decisions:

1. **Build mechanism:** `nix build` of a custom installer image via `nvmd/nixos-raspberrypi` flake, running on the new **free linux-arm64 GitHub runners** (`ubuntu-24.04-arm`). No QEMU emulation. Expected wall-clock ~5–10 min with the project's Cachix as a substituter; previously this would have been a 50–90 min QEMU build. **This is the load-bearing finding that makes the pivot defensible at all.**
2. **Distribution:** Keep `ci-deploy` + nginx :50011 + Monolith caching. Re-purpose, don't retire. The Monolith now caches one artifact: the NVMe-ready full-disk image (`raw-efi` from nixos-generators or equivalent). Image is published once and reused across all 10 nodes because **per-node config no longer lives in the image** — it lives on the identity USB. So the re-flash cadence drops from "every commit" to "every several months / when kernel updates land." Old `node-img.ver` versioning collapses into a single "image generation tag" stamped on the NVMe at install time, never re-flashed for config changes.
3. **Identity USB schema (new):** Adds two files on top of the existing exFAT layout — `/hostname` (kept) and a new `/config.nix` (or directory tree under `/nixos-config/`) that the booting NixOS imports via a small module + `extraSpecialArgs`. A new file `/age-key.txt` holds the *per-node* age key (kept off-Pi for hardware-swap independence). A systemd oneshot before `multi-user.target` mounts the USB read-only at `/var/lib/hyperion-id`, and `nixos-rebuild switch --flake /var/lib/hyperion-id#<hostname>` is run by an `apply-identity-config.service` on first boot only (subsequent config changes come via Colmena from the operator workstation, not via USB re-edits — but the USB-side mechanism remains as the rebuild-the-cluster-from-cold-USB recovery path).
4. **Secrets:** sops-nix with the **age key on the identity USB**. Mount happens early enough (before activation) via a mount unit. K3s token is a secret decrypted at activation. journal-upload `Trust=` is a `sops-nix` file. **One unsolved**: if the USB is missing on boot, sops-nix activation fails and the system enters the previous generation — that's actually the *correct* failure mode (NixOS rolls back), but the operational message ("the USB stick is missing") needs surfacing — a small ExecStartPre check that writes a status to journal-remote.
5. **Healthcheck:** Add a tiny `nodeinfo.service` on each node exposing `:50013/version` with the system's current generation hash + uptime. Monolith healthcheck polls it. Replaces the current "image version" check, which becomes irrelevant.
6. **AC-14 fate:** RETIRE `rpi-bootstrap.pkr.hcl`, `bootstrap.sh` (the 545-line script), `reimage.sh`, `build-bootstrap-img.yml`, `node-img.ver`. RETIRE/SIMPLIFY `ci-deploy` (smaller poller — one image, one tag). MODIFY `flash-identity-usb.sh` to write config.nix + age-key.txt. KEEP `configure-eeprom.sh` (orthogonal to NixOS), KEEP `journal-remote`, KEEP Monolith stack, KEEP SOPS+age, KEEP Ansible (now optional — Colmena replaces most of it).

Anti-complexity defense for the Old Man: **net file-count drops**. We retire ~900 lines (bootstrap.sh + rpi-bootstrap.pkr.hcl + reimage.sh + ci-deploy/poll.sh in its current form), add ~300 lines of Nix (flake.nix, identity module, hive.nix), and the *mental model* shrinks from a custom dual-image dance with version-compare-and-reflash to "one immutable image; declarative config on USB; Colmena pushes config changes." Container/process count on Monolith: ci-deploy stays (smaller), no new containers. New external dependency: `cache.nixos.org` + `nixos-raspberrypi.cachix.org` — both equivalent in trust posture to today's GitHub Releases dependency.

Anti-complexity counter the Old Man may raise: "fix the existing dbg-nvme-not-flashing pipeline instead." Counter to that counter: the *concept-level* cost of the current design — having to re-flash NVMe to change a config line — is the recurring tax. The debug pipeline closes only this round of bugs; it doesn't reduce the rate of future bugs of the same shape. NixOS removes the class of bug, not the instance.

### 2026-05-23T05:01:33Z — Free ARM64 runners change the math

Re-stating because it's load-bearing: GitHub Actions added free `ubuntu-24.04-arm` (4 vCPU) runners for public repos in 2025-08. Until I confirmed this, my prior assumption was a 60–90 min QEMU emulated Packer build was the floor. With native arm64, image builds are 5–15 min wall-clock, and Cachix means the kernel and most of the closure are pulled, not built. This invalidates one of the strongest arguments against NixOS-on-Pi (build cost) that existed even six months ago. Recommend the team **also** migrate the existing Packer workflows to `ubuntu-24.04-arm` regardless of the NixOS decision — that's a free ~6× speedup on the Debian path too.

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
- **GitHub Actions free linux-arm64 runners (GA 2025-08-07)** — https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/ — accessed 2026-05-23 — confidence: official
- **NixOS wiki — Pi 5** — https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_5 — accessed 2026-05-23 — confidence: official
- **nvmd/nixos-raspberrypi flake** — https://github.com/nvmd/nixos-raspberrypi — accessed 2026-05-23 — confidence: community (active, 543★, Cachix-backed)
- **nixos-anywhere** — https://github.com/nix-community/nixos-anywhere — accessed 2026-05-23 — confidence: official (nix-community)
- **sops-nix** — https://github.com/Mic92/sops-nix — accessed 2026-05-23 — confidence: official (Mic92)
- **Colmena** — https://github.com/zhaofengli/colmena — accessed 2026-05-23 — confidence: community (Rust, stateless, active)
- **NixOS wiki — K3s module** — https://nixos.wiki/wiki/K3s — accessed 2026-05-23 — confidence: official
- **NixOS k3s production cluster series (haseebmajid)** — https://haseebmajid.dev/series/setup-raspberry-pi-cluster-with-k3s-and-nixos/ — accessed 2026-05-23 — confidence: community (homelab practitioner, sops-nix + Colmena pattern verified)

---

## Archive

### 2026-05-04 dbg-nvme-not-flashing — resolved (status)

Four observations from May 4 about `bootstrap.sh` (early-reboot loop, `cleanup()` trap, empty `node-image/` cache, `poll.sh` prune-ordering race) were filed and addressed in subsequent commits (`ee41010 fix: write node-img.ver to NVMe p1 after successful repartition`, plus merges). Code re-verified 2026-05-17: `MAX_BOOT_ATTEMPTS=3` still at line 39, status-server start at line 268, version-stamp write at line 532. Specific symptoms either addressed or not recurring. Observations dropped from active; refile if they resurface.

### 2026-05-17 Heimdall pipeline contributions

Stage 1 proposal + Stage 5 reviews submitted across two Heimdall runs (`20260517T183851Z-dev-heimdall-tech-stack`, `20260517T213331Z-dev-heimdall-finalize`). Material findings — all verified against upstream at the time:

- Dependabot `package-ecosystem: docker` only handles `FROM` lines, NOT `xcaddy --with` or `COPY --from`. caddy-l4 plugin bumps must surface via a scheduled GHA workflow polling `mholt/caddy-l4` releases. Confirmed by dependabot-core#5103.
- `http://heimdall.lab/ca.crt` is NOT a Caddy built-in. The admin API serves the CA at `/pki/ca/local` on `localhost:2019` only; a `handle /ca.crt` block must be added explicitly.
- Komodo v2 onboarding uses TOFU `CreateOnboardingKey` flow, NOT `CreateServer`-then-extract-key. URL paths follow `/auth/login/LoginLocalUser` convention. `KOMODO_INIT_ADMIN_{USERNAME,PASSWORD}` env vars verified correct.
- Technitium API: zone creation is `/api/zones/create?zone=<n>&type=Primary` with query params (not JSON body). Auth is `Authorization: Bearer <token>`. Env vars apply first-start-only when config absent — pre-seed via API.
- Hyperion cross-host gap: `--disable=servicelb` removal is unsafe to apply incrementally; correct order is MetalLB-up → server-disable → agent-re-roll. `Hyperion/ansible/k3s-agent.yml:38` `when: not k3s_binary.stat.exists` guard silently no-ops on already-installed agents (needs explicit stop/re-install/start task).

These remain relevant to current state of the cluster but are not active observations for the present pipeline run.

---

## Stage 5.1 re-review findings (run `20260523T050133Z-dev-nixos-identity-usb`, iter-1, 2026-05-23)

Full review: `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/05-review/iac-devops-expert.md`.

### Key technical findings to retain

- **k3s NixOS module has first-class `nodeLabel` and `nodeTaint` options.** Verified against `nixos/modules/services/cluster/rancher/default.nix@release-25.11` lines 920-947. `ExecStart` is built via `lib.concatStringsSep " \\\n " ([...])` and includes `(lib.optionals (cfg.nodeLabel != [ ]) (map (l: "--node-label=${l}") cfg.nodeLabel))` and same for nodeTaint. **Implication: do NOT wrap `systemd.services.k3s.serviceConfig.ExecStart` with `lib.mkForce` to inject labels — use the module options directly.** Pattern: read per-host override file at Nix evaluation time via `lib.fileContents`, pass to `services.k3s.nodeLabel`.

- **The revision's §G.3 wrapper is the one significant technical defect** I flagged as N-1 HIGH. Cleaner alternatives exist that don't fight upstream. My Stage 1 per-host `nixosConfigurations` approach maps cleanly to this fix.

- **Colmena vs deploy-rs activity (verified 2026-05-23):** Colmena last commit 2025-11-01 (2185 stars). deploy-rs last commit 2026-02-02 (2116 stars). deploy-rs is *more* recently active. Both ~comparable star count. Worth keeping deploy-rs as an unused flake input from day 1 for cheap insurance. Pin Colmena by commit, not v0.4.0 tag (which is from 2023-05-15).

- **GitHub Actions scheduled workflow pattern in this repo:** `.github/workflows/poll-caddy-l4-releases.yml` uses `cron: '0 13 * * 1'` (weekly Monday 13:00 UTC) with `gh issue create` / `gh pr create`. This is the precedent for §E sunset enforcement workflow. Issue body template should live at `.github/issue-templates/<n>.md` (NOT `.github/ISSUE_TEMPLATE/` which is for user-initiated issues).

- **NixOS schema-version-mismatch handling pattern:** activation script with `lib.stringAfter [ "specialfs" ]` ordering, `exit 1` on mismatch. Surfaces as `failed` systemd unit, journal-remote captures it, SSH stays up. This is the "typed failure" property H1a promises in §H but the revision did not explicitly write into `hyperion-identity.nix`.

- **k3s version-skew concern:** nixpkgs 25.11 ships `k3s_1_31` / `k3s_1_32`; upstream k3s is on 1.35.x; Monolith control plane is on `rancher/k3s:v1.35.3-k3s1`. k3s officially supports ≤2 minor version server/agent skew. **This is a Phase 1 prerequisite that the revision did not name as a hard prerequisite.** Either override `services.k3s.package` or roll Monolith back; pick before Phase 1 build.

### My Stage 5.1 vote disposition

**Trending YAE with conditions.** Hard-blocker: delete §G.3 wrapper in favor of `services.k3s.nodeLabel`. If addressed in Stage 5 amendment or named as iter-2 task, my Stage 6 ballot is YAE.

### Concessions logged (STEELMANNED)

- My Stage 1 "4 of 6 H-classes eliminated" was overstated. The revision's §H "1 outright + 2 partial + 1 shifted + 1 renamed + 2 unchanged" is honest. Owned.
- My Stage 1 missed `neededForBoot = true` on the USB mount (V-6). The revision caught it.
- My Stage 1 implied `nvmd/nixos-raspberrypi` produces the full Pi 5 `config.txt` block; per V-9 it does not. The revision caught it.

### Settled knowledge to promote (after one more session)

- The k3s nixpkgs module ExecStart construction details (lines 920-947) — keep this as authoritative reference for any future k3s module override discussion.
- Schema-version mismatch handling as the "typed failure" pattern for identity USB.
- Native ARM CI runner migration is single-day, low-risk; the gotcha to grep for is `--platform=` references.

### Open questions for Stage 6 vote

1. Will the orchestrator amend §G.3 in response to N-1? (If yes: easy YAE. If no: I'd need to weigh whether the wrapper is bad-enough to NAY despite agreeing with the rest of the revision.)
2. Does the team accept keeping deploy-rs as an unused flake input from day 1? (Cheap, +20 lines `flake.nix`.)
3. Pre-Phase-1 question: do we roll Monolith back from `v1.35.3-k3s1` to match whatever nixpkgs ships, or override `services.k3s.package`?

