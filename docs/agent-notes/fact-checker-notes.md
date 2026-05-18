---
agent: Fact Checker
specialization: Empirical verification of claims against primary sources or reproducible tests
role: Adversarial — every other agent's claims are targets
last_compacted_utc: 2026-05-17T19:00:00Z
last_updated_utc:   2026-05-17T22:30:00Z
---

# Fact Checker — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (consolidate verdicts, retire stale ones, drop noise),
> then update `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Hunt for factual claims made by other agents (or by humans, or by my
own past notes) and verify them against primary sources or reproducible tests in
this repo's environment. Output is a **verdict** (CONFIRMED / REFUTED / UNVERIFIED)
with the evidence that produced it.

**Adversarial contract** (per `TEAM.md`):

- Cite the specific claim, the counter-source, and what would change the verdict.
- Primary sources only: vendor docs, manpages, kernel source, RFCs, or commands
  run in-environment that produce reproducible output. Forum posts and blog
  writeups are evidence of opinion, not fact.
- When a claim survives challenge, record it as CONFIRMED — that is a contribution.
- Critique claims, not agents. No point-scoring.

---

## Settled knowledge (post-compaction)

Stable facts verified by past runs that remain true and load-bearing. Cited
inline by run summaries below.

- **Node IMG version-stamp lifecycle** — `Hyperion/packer/rpi-node.pkr.hcl`
  step 7 writes `/boot/firmware/node-img.ver` at Packer build time;
  `bootstrap.sh:422` deletes it on each bootstrap before NVMe repartition;
  Packer re-creates it. There is no "perpetual reflash loop" antecedent in
  the current repo. (Verified 2026-05-04, still true 2026-05-17 by spot-check
  of master.)
- **`MAX_BOOT_ATTEMPTS` exec / HTTP server ordering** — `bootstrap.sh:226`
  does `exec /bin/bash`; `_start_status_server` is invoked at line 232,
  downstream of the exec. On boot attempt > MAX, the HTTP server is never
  started for this boot; describing this as "child orphaned" is incorrect.
  Correct phrasing: "process replaced before the server was ever started".
  (Verified 2026-05-04.)
- **rpi-eeprom #629 and #718** — both real GitHub issues with titles/content
  matching what the Pi Expert has cited. (Verified 2026-05-04.)
- **Promtail EOL March 2 2026** — official Grafana docs. (Verified
  2026-05-04; now in the past — log shipping moved off Promtail upstream.)
- **`network_mode: host` source-IP behaviour on Linux** — Docker docs (host
  driver page): no NAT, no userland-proxy, container sees real client IPs.
  Linux-only; Docker Desktop "host" support (4.34+) connects to a VM, not the
  bare host. (Verified 2026-05-17.)
- **`DNSStubListener=no` is the correct systemd-resolved key to free port
  53; drop-in path is `/etc/systemd/resolved.conf.d/`** — manpage
  resolved.conf(5). (Verified 2026-05-17.)
- **Docker cgroup-v2 support since 20.10 (2020)** — Docker release notes for
  20.10.0: "Support cgroup2", "cgroup2: use 'systemd' cgroup driver by default
  when available". Therefore Docker CE 29.x on Ubuntu 26.04 / systemd 259 has
  been on a cgroup-v2-capable code path for 5+ years. (Verified 2026-05-17.)
- **Ubuntu 26.04 LTS codename is "Resolute Raccoon", released 2026-04-23** —
  Canonical's official blog + documentation.ubuntu.com release-notes page.
  (Verified 2026-05-17.)
- **Docker CE apt repo `resolute` suite exists and has `docker-ce` packages
  built for Ubuntu 26.04** — `https://download.docker.com/linux/ubuntu/dists/
  resolute/Release` returns `Suite: resolute`, `Architectures: amd64 arm64
  armhf s390x ppc64el`, `Components: stable edge test nightly`. `Packages`
  lists `docker-ce 5:29.3.1-1~ubuntu.26.04~resolute` and newer. (Verified
  2026-05-17.)
- **Quad9 DoT endpoint is `tls://dns.quad9.net`** (recommended); also
  `dns11.quad9.net` (ECS) and `dns10.quad9.net` (unsecured); standard port
  853. (Verified 2026-05-17, quad9.net/service/service-addresses-and-features.)

---

## Standing watch list

Claims worth periodically re-verifying because the underlying source can change.

- **`BOOT_ORDER=0xf641` nibble meaning** — Pi bootloader docs occasionally
  reorganize. Re-verify against the bootloader-config page when the Pi
  Expert's notes are touched.
- **`dtparam=pciex1_gen=3` is an overclock (spec is Gen 2)** — Raspberry Pi
  could revise the spec. Re-verify against official Pi 5 / M.2 HAT
  documentation on each Pi-Expert compaction.
- **`auto_initramfs=1` required on Trixie** — verify against the Pi OS
  release notes for the current Trixie image being used in `rpi-node.pkr.hcl`.
- **`ci-deploy` poll interval = 300 s** — claimed in multiple docs. Verify
  against `Monolith/k3s-control-plane/docker-compose.yml` env (`POLL_INTERVAL`)
  and the ci-deploy image's actual behavior.
- **Only `NODE_SSH_PUBLIC_KEY` is a required Actions secret** — verify
  against the actual workflow YAML files under `.github/workflows/` whenever
  they're modified.
- **HAProxy current LTS line** — re-verify quarterly. As of 2026-05-17, 3.2
  is current LTS (through 2030-Q2), 3.0 is LTS (through 2029-Q2), 3.3 is
  current stable non-LTS, 2.8 / 2.6 / 2.4 are older LTS lines.
- **`caddy-l4` README "expect breaking changes" warning** — present since
  2020 and unchanged through 2026-05-17. Watch for removal as a stability
  signal.
- **Current Caddy stable** — v2.11.3 as of 2026-05-17. Track on each
  Heimdall-related compaction.
- **Hyperion k3s `--disable=servicelb` not yet set** — `k3s-agent.yml` and
  `Monolith/k3s-control-plane/docker-compose.yml` both lack the flag. ServiceLB
  + MetalLB race is latent. Re-verify when either file is touched.

---

## Verification toolkit

Preferred order of evidence, strongest first:

1. **Read the file in this repo.** `Read` tool, with `file_path:line_number`
   citation. Beats every external source for repo-specific claims.
2. **Run the command.** `Bash` tool — `rpi-eeprom-config`, `lsblk -J`,
   `systemctl cat`, `curl -sf`, `curl … | python3 -c json`, etc. The Docker
   Hub v2 registry endpoint (`/v2/repositories/<repo>/tags?…`) is far more
   reliable than scraping the HTML tag page, which truncates to 3 arches.
3. **Vendor / project documentation.** Official URL + quoted passage +
   access date. Use `WebFetch` for known URLs.
4. **Source code of the upstream project.** Linked to a specific commit or
   tag.
5. **RFC or standards document.** With section number.
6. **Manpage.** `man <thing>` — note the section.

Anything below this — forum threads, Stack Overflow, Reddit, vendor blog
posts — is **circumstantial**. It can motivate a check but cannot conclude
one.

---

## Active observations

### 2026-05-17T22:30:00Z — Pipeline run `20260517T213331Z-dev-heimdall-finalize` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/03-adversarial/fact-checker.md`. **19 CONFIRMED, 3 REFUTED, 4 UNVERIFIED.** Highlights:

- **CONFIRMED** — `technitium/dns-server:15.2.0` is current stable, multi-arch (amd64/arm64/armv7), and the in-container config path IS `/etc/dns`. `ghcr.io/moghtech/komodo-{core,periphery}:2.2.0` exist with `:2` tracking `:2.2.0`. `setup-periphery.py` accepts `--version` and `v2.2.0` is a valid tag; installs to `/usr/local/bin/periphery`, `/etc/komodo/periphery.config.toml`, `/etc/systemd/system/periphery.service`. `mongo:7.0` multi-arch, `--wiredTigerCacheSizeGB 0.25` valid (minimum). Caddy `tls internal` exists, internal CA stored at storage-key `pki/authorities/local/root.crt` (Docker data dir `/data`). Technitium env vars apply only on first start (config file does not exist). `gh release view -R … --json tagName -q .tagName` returns latest's tag as raw string. Hyperion MetalLB file list / Monolith k3s server `command: server` / `k3s-agent.yml` line 38 `when:` guard all match repo.

- **REFUTED #1** — Phase 2 step 4 Periphery onboarding flow is mechanically wrong. Draft has operator pasting a Core public key into `core_public_keys`. v2 actually uses an *onboarding key* (one-time TOFU credential minted by Core, consumed by Periphery via `--onboarding-key` flag or `onboarding_key = "..."` in TOML). Periphery generates its own keypair and sends just the public key to Core during first handshake. No `core_public_keys` line gets manually edited.

- **REFUTED #2** — Phase 1 step 10's "Periphery comes up unattached (no `core_public_keys` in config yet)" framing implies a workflow that doesn't exist. The Core public key never goes into the Periphery TOML at all; it's exchanged at the Noise layer and stored in the Periphery's keys directory.

- **REFUTED #3** — `KOMODO_INIT_ADMIN_USERNAME/PASSWORD` env-var names unverified against `core.config.toml` upstream; flagged as needing exact citation in the revision since they're load-bearing in the SOPS env list.

- **UNVERIFIED #1** — The Caddyfile `:80 handle /ca.crt file_server` shorthand hides a real implementation gap. `file_server` serves from a *directory*, not a single file. Real form needs `rewrite * /root.crt` + `file_server { root /data/caddy/pki/authorities/local }`. Revision should spell it out.

- **UNVERIFIED #2** — "Under 256 MB combined Komodo+Mongo footprint" is not in primary sources; realistic minimum is ~0.5 GB. Cap at WiredTiger 256 MB only restricts mongod's cache, not the aggregate process RSS.

- **UNVERIFIED #3 & #4** — Komodo UI exact button labels ("Generate Onboarding Key") and the Hyperion ansible re-install task design (existing `args.creates: /usr/local/bin/k3s` will short-circuit any re-run regardless of `when:` — revision must say whether the new task is separate or removes the creates).

- **New fact surfaced** — Komodo Core `:latest` on GHCR does NOT point at `:2.2.0`'s digest (or any `2.x.y` stable digest). It tracks a `*-dev` build. Pinning to `:2.2.0` is strictly necessary; `:latest` is actively harmful, not just deprecated.

- **New fact surfaced** — `setup-periphery.py` only `systemctl start`s, never `systemctl enable`s; the draft's `enable --now` is necessary for reboot survival. And the script skips writing config if `/etc/komodo/periphery.config.toml` exists, so the draft's `install -m 0640` over-write step interacts subtly with re-runs — revision should choose one ownership pattern.

- **New fact surfaced** — k3s `--disable=servicelb` is server-only-required; the agent-side `INSTALL_K3S_EXEC` in the draft is belt-and-suspenders, not load-bearing. Disabling on the Monolith server uninstalls the cluster-wide DaemonSet.

### Verdict file location

`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/03-adversarial/fact-checker.md`.

### 2026-05-17T19:00:00Z — Pipeline run `20260517T183851Z-dev-heimdall-tech-stack` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/iter-1/03-adversarial/fact-checker.md`. 16 CONFIRMED, 4 REFUTED, 3 UNVERIFIED. Highlights:

- **CONFIRMED** — caddy-l4 README "still in development; expect breaking changes" warning is present (and **has been present unchanged since at least 2020-06**, across 5+ years of releases). HAProxy 3.0 is an LTS supported through 2029-Q2. AdGuard Home v0.107.74 (2026-04-16), Quad9 DoT `tls://dns.quad9.net`, Docker CE `resolute` suite (Ubuntu 26.04), Ubuntu 26.04 codename, `DNSStubListener=no`, host-mode source-IP preservation, Docker cgroup v2 since 20.10, and ARM64 manifests for all four images.

- **REFUTED #1** — Dockge v1.5.0 release date is **2025-03-30**, not 2026-03-30 as the draft claims. The version pin is fine; the framing is wrong. Also worth noting: Dockge has had no newer release in 13+ months.

- **REFUTED #2** — HAProxy FTP recipe does **not** use `ct helper "ftp"`. That's an **nftables** conntrack directive (`nf_conntrack_ftp`), not a HAProxy directive. The actual `haproxy.com` passive-FTP recipe uses stick-tables + a frontend binding both the control port and the PASV range. Important correction; the recipe still works without HAProxy Enterprise.

- **REFUTED #3** — HAProxy 3.0 is **an** LTS but not the **current** LTS. 3.2 (released 2025-05-28, supported through 2030-Q2) is the newer LTS. Recommend re-pin `haproxy:3.0-alpine` → `haproxy:3.2-alpine`. Same image lineage, same recipe, 12 extra months of EOL runway.

- **REFUTED #4** — Pinning Caddy at v2.11.1 is a mistake. Current stable is v2.11.3 (released 2026-05-12, five days before the draft). v2.11.1 itself is a release-machinery do-over of a broken v2.11.0 ("no code changes from v2.11.0 other than to a CI job") — the maintainer explicitly flags it. Recommend re-pin to v2.11.3 or `2.11`.

- **UNVERIFIED #1** — Whether `caddy-l4`'s "breaking changes" warning is load-bearing-by-evidence vs conservative-hedging. The warning has stood since 2020 (strongly suggests stale), but recent issues include user-visible matcher bugs and the project is mid-1.x. The §3-A judgment call is not refutable on data; both the Linux Expert's and the Old Man's reads survive.

- **UNVERIFIED #2** — Whether MetalLB L2 + Heimdall-fronted reverse proxy on the same /24 is a documented-clean pattern. MetalLB's documented ARP failure modes (multi-replica + `externalTrafficPolicy: Local` ARP storm, bridge non-response, IPVS strictARP) do not apply here. Architectural assumption is sound; a definitive vendor "yes" doesn't exist.

- **New fact A surfaced** — **The Pi Expert's archived ServiceLB-vs-MetalLB latent-conflict claim is empirically grounded.** `Hyperion/ansible/k3s-agent.yml:32-38` installs k3s with no `INSTALL_K3S_EXEC` flag → ServiceLB enabled on every agent. `Monolith/k3s-control-plane/docker-compose.yml:4` runs `command: server` with no `--disable=servicelb,traefik`. Heimdall's contract "Caddy → stable MetalLB VIP" is undefined while ServiceLB also races to fulfill `Service type=LoadBalancer`. Criterion 6 ("reconstruct from scratch using only this repo") cannot be honestly claimed until Hyperion is fixed. This is the most important finding of the run beyond the four required edits.

### Verdict file location

`docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/iter-1/03-adversarial/fact-checker.md`.

### 2026-05-04T00:35:00Z — Pipeline run `20260504T000719Z-dbg-nvme-not-flashing` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/03-adversarial/fact-checker.md` (V-1 through V-22). Key outcomes (full detail promoted into Settled knowledge above; specifics remain in the ledger file):

- **REFUTED — V-1: Old Man H5 sub-finding "latent reflash-loop bug" (Node IMG missing `node-img.ver`).** Packer step 7 writes the stamp; bootstrap deletes it pre-repartition. Antecedent is false.
- **PARTIAL — V-12: §1 description of `MAX_BOOT_ATTEMPTS` exec.** Correct mechanism is "process replaced before the server was ever started", not "orphaned and dies".
- **CONFIRMED — V-2 through V-9, V-11, V-13 through V-19, V-21, V-22.** All file-line citations verified by direct read. EXIT trap fires on SIGTERM. rpi-eeprom #629 / #718 real. Promtail EOL March 2 2026 confirmed.
- **PARTIAL — V-17:** "256 GB SSDs per CLAUDE.md" — actually in the agent's project memory, not the repo CLAUDE.md. Citation should be tightened.
- **Independent observation logged in V-13 (not a refutation)** — `systemctl reboot` is async; in the "NVMe is current" path there's no `exit` so a small race window exists where `dd` could begin before systemd-shutdown terminates the unit. Not load-bearing for the user's reported symptom.

---

## Sources (verification references)

### General / Linux / Pi

- **Raspberry Pi bootloader configuration** —
  https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration —
  accessed 2026-05-03 — confidence: official
- **`config.txt` reference** —
  https://www.raspberrypi.com/documentation/computers/config_txt.html —
  accessed 2026-05-03 — confidence: official
- **systemd.mount(5) / systemd.unit(5)** —
  https://www.freedesktop.org/software/systemd/man/ —
  accessed 2026-05-03 — confidence: official
- **systemd-resolved resolved.conf(5)** —
  https://man.archlinux.org/man/resolved.conf.5 —
  accessed 2026-05-17 — confidence: official (Arch mirrors upstream)
- **GitHub REST API — Releases** —
  https://docs.github.com/en/rest/releases/releases —
  accessed 2026-05-03 — confidence: official
- **k3s docs** — https://docs.k3s.io —
  accessed 2026-05-03 — confidence: official

### Heimdall-stack verification (2026-05-17 run)

- **`caddy-l4` README and release history** — `raw.githubusercontent.com/mholt/caddy-l4/master/README.md`, `api.github.com/repos/mholt/caddy-l4/releases`, `api.github.com/repos/mholt/caddy-l4/commits?path=README.md`. Accessed 2026-05-17. Confidence: official (project itself).
- **HAProxy release table / LTS policy** — `https://www.haproxy.org/`. Accessed 2026-05-17. Confidence: official.
- **HAProxy passive FTP recipe** — `https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/passive-ftp/`. Accessed 2026-05-17. Confidence: official.
- **AdGuard Home releases + asset list** — `https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/tags/v0.107.74`. Accessed 2026-05-17. Confidence: official.
- **AdGuard Home configuration schema (`filtering.rewrites`)** — `https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration`. Accessed 2026-05-17. Confidence: official.
- **Quad9 service addresses** — `https://www.quad9.net/service/service-addresses-and-features/`. Accessed 2026-05-17. Confidence: official.
- **Caddy releases** — `https://api.github.com/repos/caddyserver/caddy/releases`. Accessed 2026-05-17. Confidence: official.
- **`caddy-dns/cloudflare` Dockerfile** — `https://github.com/caddy-dns/cloudflare/blob/master/Dockerfile`. Accessed 2026-05-17 (via WebSearch summary). Confidence: official (plugin repo).
- **Docker CE apt repo / `resolute` suite** — `https://download.docker.com/linux/ubuntu/dists/resolute/Release` and `…/stable/binary-amd64/Packages`. Accessed 2026-05-17. Confidence: official.
- **Canonical Ubuntu 26.04 release announcement** — `https://canonical.com/blog/canonical-releases-ubuntu-26-04-lts-resolute-raccoon` and `https://documentation.ubuntu.com/release-notes/26.04/`. Accessed 2026-05-17. Confidence: official.
- **Dockge releases** — `https://api.github.com/repos/louislam/dockge/releases`. Accessed 2026-05-17. Confidence: official.
- **Docker Hub v2 registry tag-manifest queries** — `https://hub.docker.com/v2/repositories/{adguard/adguardhome,library/haproxy,library/caddy,louislam/dockge}/tags`. Accessed 2026-05-17. Confidence: official (registry).
- **Docker host networking driver** — `https://docs.docker.com/engine/network/drivers/host/`. Accessed 2026-05-17. Confidence: official.
- **Docker 20.10 release notes (cgroup2 support)** — `https://docs.docker.com/engine/release-notes/20.10/`. Accessed 2026-05-17. Confidence: official.
- **MetalLB troubleshooting** — `https://metallb.universe.tf/troubleshooting/`. Accessed 2026-05-17 (via WebSearch summary). Confidence: official.

### Heimdall-finalize verification (2026-05-17 second run)

- **Technitium upstream `docker-compose.yml`** — `https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/docker-compose.yml`. Accessed 2026-05-17. Confidence: official upstream. Confirms `/etc/dns` config mount.
- **Technitium `DockerEnvironmentVariables.md`** — `https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/DockerEnvironmentVariables.md`. Accessed 2026-05-17. Confidence: official upstream. Confirms env vars only-on-first-start.
- **Technitium image tags + manifests** — `https://hub.docker.com/v2/repositories/technitium/dns-server/tags/{15.2.0/,?...}`. Accessed 2026-05-17. Confidence: official registry.
- **Komodo `setup-periphery.py`** — `https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py`. Accessed 2026-05-17. Confidence: official upstream. Full script read.
- **Komodo upstream `periphery.config.toml`** — `https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml`. Accessed 2026-05-17 (via WebFetch). Confidence: official upstream. Confirms passkeys deprecated + `core_public_keys` v2 syntax.
- **Komodo docs — setup, connect-servers, mongo** — `https://komo.do/docs/{setup,setup/connect-servers,setup/mongo}`. Accessed 2026-05-17. Confidence: official project docs. Connect-servers page confirms onboarding-key workflow.
- **GHCR registry API for `moghtech/komodo-{core,periphery}`** — `https://ghcr.io/v2/moghtech/komodo-core/{tags/list,manifests/<tag>}` with anonymous bearer token from `ghcr.io/token?service=ghcr.io&scope=repository:moghtech/komodo-core:pull`. Accessed 2026-05-17. Confidence: official registry. Confirms `:2.2.0`, `:2.2`, `:2`, `:latest` tag existence and digests.
- **GitHub release `v2.2.0` for moghtech/komodo** — `https://api.github.com/repos/moghtech/komodo/releases/tags/v2.2.0`. Accessed 2026-05-17. Confidence: official. Published 2026-05-07, prerelease: false.
- **k3s docs — packaged-components, cli/server, networking-services** — `https://docs.k3s.io/{installation/packaged-components,cli/server,networking/networking-services}`. Accessed 2026-05-17. Confidence: official.
- **MongoDB v7.0 mongod options** — `https://www.mongodb.com/docs/v7.0/reference/program/mongod/`. Accessed 2026-05-17. Confidence: official.
- **Docker Hub `library/mongo` tags** — `https://hub.docker.com/v2/repositories/library/mongo/tags/{7.0/,?...}`. Accessed 2026-05-17. Confidence: official registry.
- **Caddy docs — automatic-https, directives index, `tls`, `file_server`, `respond`, `rewrite`, `caddy trust`, conventions** — `https://caddyserver.com/docs/{automatic-https,caddyfile/directives,caddyfile/directives/{tls,file_server,respond,rewrite},command-line,conventions}`. Accessed 2026-05-17. Confidence: official.
- **Caddy internal-CA root path** — `https://github.com/caddyserver/caddy/blob/master/modules/caddypki/ca.go` (`storageKeyRootCert()`). Accessed 2026-05-17. Confidence: official source code. Storage key `pki/authorities/local/root.crt`.
- **Caddy Docker image data dir `/data`** — `https://hub.docker.com/_/caddy`. Accessed 2026-05-17. Confidence: official.
- **gh CLI manual — `gh release view`** — `https://cli.github.com/manual/gh_release_view`. Accessed 2026-05-17. Confidence: official. Confirms "without explicit tag → latest" and `--json … -q` jq filter behavior.
- **mholt/caddy-l4 latest release** — `https://api.github.com/repos/mholt/caddy-l4/releases/latest`. Accessed 2026-05-17. Confidence: official. v0.1.1, 2026-05-14.

---

## Archive

Verdicts whose subject was removed from the repo, or that were superseded by a
later verification. Kept for historical context.

(empty)
