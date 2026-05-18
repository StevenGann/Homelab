---
agent: Linux Expert
specialization: Debian/Trixie, systemd, networking, filesystems, kernel, package management, shell
last_compacted_utc: 2026-05-17T18:42:00Z
last_updated_utc:   2026-05-17T21:55:00Z
---

# Linux Expert — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Anything below the application layer that runs on Linux: systemd units
and ordering, mount logic and udev, networking stack, filesystem choices, kernel
parameters, package management, shell idioms, and standard sysadmin reasoning.

---

## Settled knowledge

### Hyperion-specific repo facts

- Node OS is **Debian Trixie (Pi OS Lite arm64)**. Trixie uses initramfs by default;
  `auto_initramfs=1` in `config.txt` is required for the Pi 5 boot path.
- `cloud-init` is **purged** from the Node IMG. Identity is set by
  `apply-identity.service` reading `/dev/disk/by-label/HYPERION-ID`. Do not
  reintroduce cloud-init.
- `/mnt/node-storage` is mounted **only** by `mnt-node-storage.mount`
  (systemd unit). Bootstrap deliberately does not write a fstab entry — duplicate
  mounts would create a unit conflict.
- Node detection logic: `detect-node-storage.service` writes a drop-in at
  `/run/systemd/system/mnt-node-storage.mount.d/override.conf` and runs
  `systemctl daemon-reload`. The override sets `What=` to the chosen device.
- SSH user on production nodes is `owner`. The default `pi` user is **deleted**
  during Packer build.
- Bootstrap medium runs sshd as `pi:raspberry` — useful live-debug lever
  (`Hyperion/packer/rpi-bootstrap.pkr.hcl:84-100`).
- `bootstrap.sh:396` guard `[ "$NVME_VER" -ge "$USB_VER" ]` short-circuits when
  both default to `0`. Documented root cause for the May-2026 "SSD not flashing"
  symptom. Fix: require `NVME_VER -gt 0` for the skip-flash branch.
- Bootstrap medium uses **dhcpcd** (Pi OS Lite default), not systemd-networkd, so
  `systemd-networkd-wait-online.service` is a no-op and
  `network-online.target` resolves prematurely; the `NET_WAIT=60` polling loop
  added in commit `8a21d6b` only checks for a default route, not reachability.
- `systemd-journal-upload` is the canonical Homelab log-shipping mechanism.
  Both Hyperion image variants enable it and push to `http://192.168.10.247:19532`
  via a drop-in at `/etc/systemd/journal-upload.conf.d/monolith.conf`. Package on
  Trixie is `systemd-journal-remote` (sender + receiver come in the same pkg).
  Default TCP port 19532.

### Monolith-specific repo facts

- Static host (TrueNAS Scale), Docker Compose stack at
  `Monolith/k3s-control-plane/docker-compose.yml`. Pattern: static OS, bind-mounted
  config from `/mnt/.../Container-Data/...`, services pulled from
  `ghcr.io/stevengann/homelab-*`.
- `journal-remote` container baked from `debian:trixie-slim` (Dockerfile in repo).
  Listens HTTP on `:19532`. Writes to `/var/log/journal/remote/` with
  `--split-mode=host` → one `.journal` file per source hostname.
- Image registry: nginx on `:50011`, served from `/mnt/Media-Storage/Infra-Storage/images`.
- ci-deploy poller: `homelab-ci-deploy` polls GitHub Releases every 5 min, writes
  to `/images`.
- healthcheck API on `:50012/summary`.

### General sysadmin knowledge worth keeping

- `systemd-journal-upload.service` — Debian package `systemd-journal-remote`;
  config `/etc/systemd/journal-upload.conf` plus drop-ins under
  `/etc/systemd/journal-upload.conf.d/*.conf`. Default port 19532. Tolerates
  receiver outages — buffers locally up to `Storage.MaxSize`.
- Trixie systemd-resolved interaction: stub listener at `127.0.0.53:53`. If the
  host needs to *host* a DNS server on `:53`, `systemd-resolved` must be either
  disabled or configured with `DNSStubListener=no`. `/etc/resolv.conf` must then
  point somewhere that won't loop (e.g. the container's published IP, or
  `127.0.0.1` once the container is up — chicken-and-egg risk on boot).
- Docker on Ubuntu 26.04 LTS: install path is the upstream
  `docker-ce` repository, not Ubuntu's `docker.io` package (older, lacks
  Compose v2 plugin). Compose v2 is the `docker compose` (no dash) plugin
  command, not the deprecated `docker-compose` Python script.
- netplan defaults to `networkd` renderer on Ubuntu Server. Multi-NIC hosts:
  per-interface YAML under `/etc/netplan/`. Permissions must be `0600` since
  netplan 0.106 or the parser warns and (in newer versions) fails.
- For DNS authority on a host with `:53` exposed: nftables `chain input { tcp dport 53 accept; udp dport 53 accept; }` only. Never publish recursion to
  the upstream interface.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-17T18:42:00Z — Stage 1 research for Heimdall tech stack

Run `20260517T183851Z-dev-heimdall-tech-stack`. New sources fetched today (full
URLs in Sources section). Highlights and corrections:

- **Ubuntu 26.04 LTS codename is "Resolute Raccoon"** (not "Rhino" — pre-Stage-1
  training-data guess was wrong). Confirmed against
  `documentation.ubuntu.com/release-notes/26.04/`. systemd **259** (not 257),
  cgroup v1 **removed** entirely, **dracut** replaces initramfs-tools as default
  initrd. Released 2026-04-23.
- **Docker CE on Ubuntu 26.04**: `resolute` apt suite is live at
  `download.docker.com/linux/ubuntu`. Docker 29 had day-one support for 26.04.
  Standard package set: `docker-ce docker-ce-cli containerd.io
  docker-buildx-plugin docker-compose-plugin`. Ubuntu's `docker.io` package
  lags upstream — use the upstream apt repo.
- **AdGuard Home v0.107.x** is the current stable line (April 2026 release on
  Docker Hub). DoT/DoH upstream supported natively (`tls://`, `https://`
  prefix on `upstream_dns:` list). State paths `/opt/adguardhome/work` and
  `/opt/adguardhome/conf`.
- **Caddy v2.11.x** is the current line (v2.11.3 published 2026-05-12).
  Notable: built-in HTTP/3 + ACME ECH key rotation, several CVEs fixed.
- **caddy-l4 v0.1.1** (May 2026) is still upstream-flagged "in development;
  expect breaking changes" — verified against the project README today. This
  is the load-bearing reason to keep L4 traffic on HAProxy, not on Caddy.
- **HAProxy 3.0 LTS** native `mode tcp` + `stick-table type ip` is the
  canonical pattern for FTP passive (bind passive port range, pin client to
  one backend across control + data connections). UDP supported since 2.6 —
  not needed in v1.
- **Dockge** latest release April 2026; v1.4+ has multi-host management.
  Single-author OSS, no licensing wrinkles.
- **systemd-resolved port-53 conflict** is well-documented; drop-in
  `/etc/systemd/resolved.conf.d/no-stub.conf` with `DNSStubListener=no` is
  the standard fix and does NOT require disabling the whole service.
- **netplan** on 26.04: still `networkd` default renderer on Server; YAML
  files must be `0600` or netplan warns/fails on apply; `routes: - to: default`
  is the current syntax (`gateway4` removed); `netplan try` auto-reverts after
  120 s — use it before `netplan apply` on remote hosts.
- **Quad9 / Cloudflare DoT endpoints** confirmed reachable via standard
  `tls://dns.quad9.net` / `tls://1.1.1.1` URLs in AdGuard upstream config.
  Quad9 has malware-blocking built-in server-side; Cloudflare doesn't.
- **MetalLB**: per current Hyperion plan it owns `192.168.10.10–.99` in
  L2/ARP mode. Heimdall does not replace it; Heimdall fronts L7 with the
  reverse proxy and forwards to MetalLB VIPs as upstreams.

Surprise: Canonical's announcement blog and the Discourse release page agree on
"Resolute Raccoon" — the "Rhino" name was apparently a pre-release
codename floated and discarded. Caused a documentation-source mismatch
internally; corrected in this notes file.

### 2026-05-17T19:35:00Z — Stage 5.1 re-review of iter-1 revision (same pipeline)

Wrote `docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/iter-1/05-review/linux-expert.md`.

Key shifts since my Stage 1:

- **L4 split flipped.** Revision dropped HAProxy as the v1 default; `caddy-l4`
  single-container is now the v1 design. I disagree on stability grounds but
  the team's reasoning (FC #16, hidden-cost analysis, FTP strike) is sound.
  Conceded in the review.
- **Ansible playbook shelved.** Old Man's `setup.sh` middle-path wins.
  Explicit promotion trigger documented (200 LOC / second host / fact-gathering).
- **Internal CA default for `.lab`.** Public LE is opt-in per-hostname; cert-loss
  rate-limit SPOF eliminated for v1.
- **FTP struck from v1.** No `Heimdall/ftp/` directory, no PASV range in nftables,
  no ftp-passive-mode runbook.

**Operational findings I surfaced in this re-review** (worth keeping for future
Heimdall work):

- **Docker bridge `ports:` mappings rewrite source IPs via `docker-proxy`** —
  fine for HTTP-with-`X-Forwarded-For` (Caddy reconstructs), broken for L4
  (`caddy-l4` sees `172.17.0.1`). UDP is even worse — `moby/libnetwork#1994`.
  Fix is `network_mode: host` for the Caddy container OR `userland-proxy: false`
  in `daemon.json` plus L4 source-IP verification. Naming this because the
  revision flipped to `caddy-l4` without porting the host-mode requirement that
  HAProxy had in my Stage 1 spec.
- **Caddy has no built-in HTTP endpoint for its local root CA cert.** Root is
  on disk at `{data_dir}/pki/authorities/local/root.crt`. Standard pattern is
  a `file_server` on `:80` pointing at that path. The revision's
  `http://heimdall.lab/ca.crt` URL is invented; runbook needs the Caddyfile snippet.
- **k3s `--disable=servicelb` is a server-side flag.** Agents don't run the
  klipper-lb controller. The §6.A claim that both server and agents need the
  flag is half-right; the agent edit is redundant safety, not load-bearing.
  Restarting the server with this flag removes svclb-* DaemonSets cluster-wide
  — verify `kubectl get svc -A | grep LoadBalancer` is empty (or MetalLB is
  already installed) before flipping.
- **`/etc/resolv.conf` symlink swap ordering matters.** Drop-in first, restart
  resolved (which drops the stub), then swap symlink to
  `/run/systemd/resolve/resolv.conf` (NOT `stub-resolv.conf`). If the host points
  at itself for DNS and AdGuard is the resolver, that's a chicken-and-egg trap
  on boot; the revision correctly keeps the host pointed at the UCG.

Vote-shape: trending YAE; would flip to NAY only if Caddy ships in
`network_mode: bridge` without source-IP verification on the L4 path.

### 2026-05-17T21:55:00Z — Stage 1 research for dev-heimdall-finalize (amendment run)

Run `20260517T213331Z-dev-heimdall-finalize`. Wrote
`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/01-proposals/linux-expert.md`.

Three deltas plus a phasing requirement. Linux/host-OS lens findings:

- **Technitium default port set**: 53/tcp+udp (DNS), 5380/tcp (web UI),
  optional 853 (DoT), 443 (DoH), 80 (DoH-redirect), 53443 (web UI HTTPS),
  67/udp (DHCP). Verified against upstream `docker-compose.yml`. **DoH at
  443 collides with Caddy** under `network_mode: host`. Resolution:
  Caddy keeps :443; Technitium DoH (if/when needed) goes via
  `Caddy → 127.0.0.1:8053 → Technitium DNS-over-HTTP-via-reverse-proxy`.
- **Technitium first-start env-var behavior**: `DNS_SERVER_*` env vars
  are read **only when the config file doesn't exist** (verified
  against upstream `DockerEnvironmentVariables.md`). Pre-seeding is
  thus two-layer: env vars for first-start (admin pw, forwarders,
  blocking, domain), and bind-mounted `config/` directory for zone
  files committed to repo.
- **Technitium config path** inside container: upstream compose mounts
  `./config:/etc/dns/config`. Linux Expert flagged to Stage 5 to
  verify against the current image's `WORKDIR`.
- **Technitium runtime**: ASP.NET Core 10. 1 GB RAM baseline; known
  upstream issues about cache+stats RAM growth. Recommend explicit
  container `mem_limit`.
- **Komodo Periphery default port**: 8120. Default bind `[::]` (all
  interfaces) — source filtering is on us. v1 had a passkey-empty-array
  footgun; v2 replaces passkeys with PKI (Ed25519). Onboarding requires
  Core to issue a key, then Periphery accepts. v2 came out before
  this run.
- **Komodo Periphery install paths**: Docker container OR systemd
  binary via `setup-periphery.py`. **Upstream recommendation: systemd
  for remote-managed hosts; container for compose-co-located-with-Core
  scenarios.** I argued for systemd in Phase 1 (no container manager
  exists yet; circular dependency if Periphery containerized).
- **Komodo Core has a database dependency** (MongoDB or FerretDB).
  FerretDB picked for v1 (lighter, Postgres-backed). This is a third
  v1 container alongside Technitium and Caddy.
- **MetalLB removal — Linux host side is almost a no-op.** NodePorts
  are outbound from Heimdall; no firewall change needed. The
  documentation update (drop `.10–.99` from `Hyperion/docs/network-layout.md`)
  is the only Heimdall-side artifact, and that's not on Heimdall at all.
- **Static-vs-dynamic NodePort discovery**: I recommend static config
  in Caddyfile (one `reverse_proxy <pi-1>:<np> <pi-2>:<np> …` block
  per service) with Caddy's active health checks handling node-down.
  Dynamic discovery (k8s API watcher) would add a daemon, a kubeconfig,
  and an RBAC role for ~weekly churn — the cost-benefit is wrong.

**Iter-1 known concerns** — accounted for each (table in proposal).
Most carry forward unchanged; #5 expands by one sub-bullet (Periphery
idempotence guard); #6 is *superseded* by full MetalLB removal; #8's
"12→4 steps" marketing claim should be deleted; #11's backup paths
change (Technitium replaces AdGuard, Komodo+FerretDB added).

### 2026-05-17T22:50:00Z — Stage 5.1 re-review of iter-1 revision (finalize run)

Wrote `docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/05-review/linux-expert.md`.

Corrections to my own Stage 1 / settled knowledge:

- **Komodo Periphery `allowed_ips = []` means "accept from anywhere," not
  "from nowhere."** Verified directly against upstream
  `config/periphery.config.toml`: comment reads "Default: empty, which will
  not block any request by ip." My Stage 1 had the inverse. Promote to
  settled: `allowed_ips = []` is open-by-default; nftables source-CIDR is
  the only IP-layer gate unless operator configures the TOML.
- **Komodo Periphery defaults to HTTPS on `:8120`, not HTTP.**
  `ssl_enabled = true` in default config; setup-periphery.py auto-generates
  self-signed cert/key at `/etc/komodo/ssl/{key,cert}.pem`. The revision's
  `onboard-periphery.sh` uses `http://127.0.0.1:8120` for `PERIPHERY_ADDR`
  which is wrong — will fail TLS handshake. Flagged as the one MAJOR
  pre-merge fix.
- **Periphery keypair persists at `/etc/komodo/periphery.key`** (per
  upstream config comment `file:${root_directory}/keys/periphery.key`
  pattern). Survives reboot, survives `systemctl restart periphery`,
  survives setup-periphery.py re-run (script skips existing config).
- **k3s installer writes `INSTALL_K3S_EXEC` to
  `/etc/systemd/system/k3s-agent.service.env`.** Path is correct in the
  §D.6 revision. `grep -q 'disable=servicelb'` is too narrow — catches
  servicelb-disable but doesn't notice if `--disable=traefik` should also
  land. Documented as MINOR.
- **`sed -i` on Linux replaces the inode and inherits caller's umask.**
  Mode/ownership of `/etc/komodo/periphery.config.toml` after the
  `onboard-periphery.sh` sed will be `0644` not the pre-existing `0600`.
  Fix is explicit `chmod 0600 && chown root:root` after sed. Promote to
  settled sysadmin knowledge — `sed -i.bak` is not mode-preserving.
- **`:80` IS a valid Caddyfile site address (bare port).** Web-verified.
  Combined with `auto_https disable_redirects` in global options, the
  revision's `:80` block has clean ownership of port 80 for the `/ca.crt`
  file_server. Future public-LE hostnames will collide on `:80` for
  ACME-HTTP-01; document the fix in `adding-a-route.md`.

Vote-shape: trending YAE-with-conditions; pre-merge fixes needed are HTTPS
scheme in onboard-periphery.sh (~2 min) and `source .env` hardening
(~10 min). Not architectural; the revision's foundation holds.

---

## Sources

- **systemd.mount(5)** — canonical reference for mount unit syntax and ordering.
  https://www.freedesktop.org/software/systemd/man/systemd.mount.html — accessed
  2026-05-03 — confidence: official
- **Debian Trixie release notes** — current stable release, kernel/init changes.
  https://www.debian.org/releases/trixie/releasenotes — accessed 2026-05-03 —
  confidence: official
- **systemd-journal-upload.service(8) — Debian Trixie** — confirms package is
  `systemd-journal-remote`, default TCP port 19532, config files
  `/etc/systemd/journal-upload.conf` and `/etc/systemd/journal-remote.conf`.
  https://manpages.debian.org/trixie/systemd-journal-remote/systemd-journal-upload.service.8.en.html
  — accessed 2026-05-04 — confidence: official Debian manpage
- **Ubuntu 26.04 LTS release notes** — feature set, kernel, systemd version.
  https://discourse.ubuntu.com/t/ubuntu-26-04-lts-resolute-rhino-release-notes/
  — accessed 2026-05-17 — confidence: official Canonical
- **Docker Engine install on Ubuntu** — upstream apt repo path, package set.
  https://docs.docker.com/engine/install/ubuntu/ — accessed 2026-05-17 —
  confidence: official vendor
- **AdGuard Home wiki — Docker image** — env, volume, port plan.
  https://github.com/AdguardTeam/AdGuardHome/wiki/Docker — accessed
  2026-05-17 — confidence: official upstream
- **Caddy docs — layer4 plugin** — TCP/UDP routing.
  https://caddyserver.com/docs/modules/layer4 — accessed 2026-05-17 —
  confidence: official
- **HAProxy 3.0 documentation** — TCP mode, ct-helper integration for FTP.
  https://docs.haproxy.org/3.0/ — accessed 2026-05-17 — confidence: official
- **Dockge GitHub README** — Compose stack manager.
  https://github.com/louislam/dockge — accessed 2026-05-17 — confidence: official
- **systemd-resolved(8)** — `DNSStubListener=` option, port-53 conflict.
  https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html
  — accessed 2026-05-17 — confidence: official
- **netplan reference** — Ubuntu 26.04 default renderer, multi-NIC layout.
  https://netplan.readthedocs.io/en/stable/ — accessed 2026-05-17 —
  confidence: official Canonical
- **Technitium DNS Server upstream docker-compose.yml** — canonical port
  set, volume mounts, network_mode hints.
  https://github.com/TechnitiumSoftware/DnsServer/blob/master/docker-compose.yml
  — accessed 2026-05-17 — confidence: official upstream
- **Technitium DNS Server Docker environment variables** — first-start
  init contract (env-vars only read when config absent), full `DNS_SERVER_*`
  list, forwarders/OIDC syntax.
  https://github.com/TechnitiumSoftware/DnsServer/blob/master/DockerEnvironmentVariables.md
  — accessed 2026-05-17 — confidence: official upstream
- **Komodo Periphery default config.toml** — port 8120, bind `[::]`,
  allowed_ips, root_directory `/etc/komodo`, passkey deprecated.
  https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml
  — accessed 2026-05-17 — confidence: official upstream
- **Komodo Core + Periphery installation guide** —
  Docker-container vs systemd-binary install paths; remote-host recommendation.
  https://deepwiki.com/moghtech/komodo/11.1-core-and-periphery-installation
  — accessed 2026-05-17 — confidence: derived from upstream (DeepWiki)
- **Komodo connect-servers (komo.do docs)** — port 8120, PKI v2.
  https://komo.do/docs/setup/connect-servers — accessed 2026-05-17 —
  confidence: official upstream
- **Komodo Periphery security discussion (#1319)** — v1 passkey
  footgun history, v2 PKI rollout, source-IP restriction recommendation.
  https://github.com/moghtech/komodo/discussions/1319 — accessed
  2026-05-17 — confidence: maintainer discussion thread

---

## Archive
