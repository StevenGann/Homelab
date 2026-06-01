---
agent: Fact Checker
specialization: Empirical verification of claims against primary sources or reproducible tests
role: Adversarial — every other agent's claims are targets
last_compacted_utc: 2026-05-17T19:00:00Z
last_updated_utc:   2026-05-23T05:30:00Z
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

### NixOS / Pi 5 ecosystem (nixos-identity-usb run, 2026-05-23)

- **`nvmd/nixos-raspberrypi`** is the active Pi 5 NixOS flake. Default branch
  `develop`, not archived, ~543 stars. Latest release **`v1.20260517.0`**
  (2026-05-17). API: `nixos-raspberrypi.lib.nixosSystem { ... }`. Pi 5 module
  selects `linuxPackages_rpi5`, adds `nvme` to initrd modules, and sets
  `bootloader = "kernelboot"` by default; `"kernel"` (generational) is the
  recommended new-install value per upstream README. The flake's modules emit
  `enable_uart=1` and base console params, but DO NOT auto-emit
  `dtparam=nvme`, `dtparam=pciex1_gen=3`, `auto_initramfs=1`, or
  `usb_max_current_enable=1` — operator must add via
  `hardware.raspberry-pi.config`. (Verified 2026-05-23.)
- **`nix-community/raspberry-pi-nix`** archived 2025-03-23. README's
  "What's not working?" section explicitly lists "Pi 5 u-boot devices other
  than sd-cards (i.e. usb, nvme)." (Verified 2026-05-23.)
- **Cachix substituter `https://nixos-raspberrypi.cachix.org`** operational;
  returns valid `nix-cache-info` (StoreDir=/nix/store, Priority=41). Public
  key `nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=`.
  (Verified 2026-05-23.)
- **`services.k3s` NixOS module options exist:** `tokenFile` (`nullOr path`),
  `serverAddr`, `role`, `extraFlags`, `manifests`, `environmentFile` — all
  present at release-25.11. Module lives under
  `nixos/modules/services/cluster/rancher/{default.nix,k3s.nix}` (shared base
  with `rke2`), NOT `services/cluster/k3s/`. Service unit interpolates token
  path as `--token-file ${cfg.tokenFile}`, so `sops.secrets.<name>.path`
  works as a runtime-resolved value. (Verified 2026-05-23.)
- **`services.journald.upload`** exists in release-25.11
  (`nixos/modules/system/boot/systemd/journald-upload.nix`). Interface is
  `settings.Upload.URL` as a `str`. Module is freeform-typed via
  `pkgs.formats.systemd`. Plain HTTP works. (Verified 2026-05-23.)
- **sops-nix activation timing.** Does NOT automatically order itself after
  arbitrary `fileSystems.` mounts. Operator must set `neededForBoot = true`
  on any filesystem hosting the age key. (Verified 2026-05-23 from
  `Mic92/sops-nix` README.)
- **Colmena release lag.** Latest tag **v0.4.0 (2023-05-15)**; no 2024/25/26
  releases. Active commits in 2025 (most recent 2025-11-01). Supports parallel
  deploy and `deployment.keys`-style secret upload. No native sops-nix
  integration — composition via `sops.secrets.<name>.path` is the idiom.
  (Verified 2026-05-23.)
- **NixOS 25.11 "Xantusia"** released 2025-11-30, EOL **2026-06-30**. NixOS
  channels move every 6 months; no LTS line. (Verified 2026-05-23.)
- **GitHub Actions `ubuntu-24.04-arm` runners GA 2025-08-07** for public
  repos at no cost. 4 vCPU. Also `ubuntu-22.04-arm` and `windows-11-arm`.
  Per GitHub changelog
  `github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/`.
  (Verified 2026-05-23.)
- **firmware-2712 latest:** 2026-05-22 ("Allow string values to enable
  fragments"). Default release: 2026-05-11. (Verified 2026-05-23.)
- **rpi-eeprom #629 / #718 still open or closed-not-planned.** #629 ("Rpi 5
  NVMe boots only if USB-MSD is there") closed as not-planned. #718 ("pi5
  second PCIe boot fails", warm-reboot NVMe enumeration failure with
  `0x0001e08f`) created 2025-06-23, still open. (Verified 2026-05-23.)
- **`nixos-anywhere` Pi 5 kexec status.** Upstream README requires x86-64
  Linux with kexec by default; aarch64 supported via BYO image. Pi 5
  specifically not singled out. Practitioner reports suggest kexec on Pi 5
  is fragile; `dd` of installer image to NVMe on workstation is the safer
  pattern. (Verified 2026-05-23.)
- **Phase 0 "load-bearing fixes" from prior FINAL.md mostly non-applicable
  in HEAD.** `Akasha/.../journal-remote/Dockerfile` already has
  `--listen-http=19532`. `Hyperion/packer/rpi-node.pkr.hcl:229–230` UART
  inserts already use `grep -q ... ||` idempotent guard (introduced in
  commit `a46cc5f` on 2026-05-03, BEFORE the prior debug anchor `ee41010`).
  `Hyperion/configure-eeprom.sh` contains no `rpi-eeprom-update -a` and no
  `PCIE_PROBE=1` writes — nothing to re-order. (Verified 2026-05-23 via
  direct file read + grep.)

### Older settled (kept for context)

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
  against `Akasha/k3s-control-plane/docker-compose.yml` env (`POLL_INTERVAL`)
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
  `Akasha/k3s-control-plane/docker-compose.yml` both lack the flag. ServiceLB
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

### 2026-06-01 — Pipeline run media-arr-stack iter-2, Fact Checker re-verification

Re-verified the load-bearing claims the iter-2 NAY objections turn on. Headline corrections to the iter-1 revision:

- **REFUTED — seerr pin `:v3.2.0` / digest `5f1a70ec9197…`.** GHCR `seerr-team/seerr` `tags/list` (anon bearer) publishes **only `v3.0.0` and `v3.0.1`** as semver version tags — NO `v3.1.x`/`v3.2.x` image tags exist. GitHub *Releases* lists v3.2.0/v3.1.1/v3.1.0 (2026-02→04) but those are NOT pushed as image version tags, so they are not deployable by tag/digest as the iter-1 revision wrote. **Correct deployable pin: `v3.0.1` → index digest `sha256:1b5fc1ea825631d9d165364472663b817a4c58ef6aa1013f58d82c1570d7c866`**, registry-confirmed multi-arch (linux/amd64 + linux/arm64). The carried NAY's recommendation is exactly correct.
- **CONFIRMED, STRONGER — seerr honors plain `API_KEY` env.** Primary source `server/lib/settings/index.ts` (develop, commit c04172a) lines 794-848: `generateApiKey()` returns `process.env.API_KEY` if set; on first boot `if(!apiKey) apiKey=generateApiKey()`, AND on every subsequent boot `else if(process.env.API_KEY){ if(apiKey!=env) apiKey=env }` — re-syncs if env changes. Env name is `API_KEY` (NOT `SEERR__AUTH__APIKEY`). `CONFIG_DIRECTORY` controls settings.json path (line 390). seerr is fork of Overseerr; settings module moved to `server/lib/settings/index.ts`.
- **CONFIRMED — `boot.supportedFilesystems=["nfs"]` ≠ `environment.systemPackages=[pkgs.nfs-utils]`.** nixpkgs `nixos/modules/tasks/filesystems/nfs.nix` @ release-25.11: a single `lib.mkIf (config.boot.supportedFilesystems.nfs or .nfs4)` (line 117) gates `services.rpcbind.enable=true` (134), `services.nfs.idmapd.settings` (136), `system.fsPackages=[pkgs.nfs-utils]` (150, puts mount.nfs on mount PATH), `systemd.packages=[pkgs.nfs-utils]` (154, wires rpc-statd/rpc-gssd units 199/207). Bare systemPackages does NOT trip this mkIf → omits rpcbind+statd. L-1/FC objection valid; iter-1 "(or, equivalently)" parenthetical must be struck.
- **CONFIRMED — `__AUTH__APIKEY` is per-app-conditional on AuthOptions.** Servarr Wiki documents `<APP>__<SECTION>__<SETTING>` double-underscore → maps to AuthOptions in config.xml; `RADARR__AUTH__APIKEY` "can be provided to set the API key manually." Radarr #11157 = no `_FILE` variant (Won't Fix). Whisparr #992 (STILL OPEN) = env IGNORED because AuthOptions class is *missing* in Whisparr — the counter-example proving the grep-gate is necessary. Sonarr #6744 = a *different* single-underscore `SONARR_API_KEY` scheme, closed-not-planned. iter-1 §6 framing accurate.
- **CONFIRMED — in-tree facts.** `nfs-utils|mount.nfs|rpcbind|supportedFilesystems` = ZERO hits in `Hyperion/nixos/`. Only `hyperion-beta.nix` + `hyperion-gamma.nix` carry `hyperion.lab/memory-tier=4gb` label + `:PreferNoSchedule` taint; all 8 other hosts have `nodeTaint=[]` + no memory-tier label. All three existing Flux apps (headlamp/uptime-kuma/hermes) `dependsOn: [metallb-config]` DIRECTLY (NEW-4 convention confirmed). hermes SOPS shape = `encrypted_regex: ^(data|stringData)$`, metadata plaintext, no comments. `.sops.yaml` rule `k8s/.*\.sops\.ya?ml$` → operator + flux age keys.
- **CONFIRMED — k3s host-PATH mount.nfs requirement** (k3s #10206 real; "you might need a /sbin/mount.<type> helper program"). Note `--prefer-bundled-bin` is an additional NFS foot-gun. Supports the NEW-1/DA pod-level-canary objection: host `which mount.nfs` is necessary but the kubelet mount is the real proof.
- **CONFIRMED — Tdarr ports** (docs.tdarr.io/variables): `serverPort=8266` default (server comms), `webUIPort=8265`, `serverIP=0.0.0.0`. Remote node connects via `serverURL=http://<server>:8266`. **Minor versioning note:** current docs use node `serverURL` (full URL); the iter-1 plan's node `serverIP`+`serverPort` split is the older scheme — verify against the pinned image. internalNode toggles in-container node; arm64 server manifest real (ffmpeg-on-arm limitation = issue #1101, justifies worker-off-Pi).
- **CONFIRMED — TrueNAS mapall** (Ganesha `Squash=AllSquash; Anonymous_Uid/Gid`): every file owned by the mapall UID/GID regardless of client. iter-1 §2.2 design correct. (Watch: forum report "mapall broken for mv" — verify rename/atomic-move behaves; not a primary refutation.)
- **CONFIRMED — EXDEV/crossmnt/fsid** (man7 exports(5) + docs.kernel.org/filesystems/nfs/reexport): crossmnt child implicitly exported "with the same export options as the parent, **except for fsid=**" → distinct fsid per child → distinct st_dev → cross-child hardlink fails. Single-dataset rule sound; the §2.5 canary is the right empirical proof.
- **CONFIRMED — Homarr `SECRET_ENCRYPTION_KEY`** (homarr.dev): required, container exits (code 64) if unset, `openssl rand -hex 32` (64 hex). **CONFIRMED — Kapowarr PUID/PGID** (casvt.github.io): supported, default 0/0, docs prescribe PUID/PGID not user-override (iter-1 V-2 correction correct).
- **CONFIRMED — all arm64 manifests** by direct registry query: linuxserver/{sonarr,radarr,prowlarr}, golift/notifiarr, mrcas/kapowarr:v1.3.1, dialmaster/youtarr:v1.70.0, ciuse99/suggestarr:v2.8.0, nandyalu/trailarr, ghcr.io/{cleanuparr/cleanuparr,homarr-labs/homarr,haveagitgat/tdarr,haveagitgat/tdarr_node} all linux/arm64. The three pinned-by-version (kapowarr v1.3.1, youtarr v1.70.0, suggestarr v2.8.0) resolve multi-arch by the exact tag — deployable as written (unlike seerr).
- **UNVERIFIED (unchanged) — Trailarr runtime user model**; TrueNAS pool name (`/mnt/pool/data` assumed); `/temp` sizing. Bounded, flagged inline in the revision.

### 2026-05-23T05:30:00Z — Pipeline run `20260523T050133Z-dev-nixos-identity-usb` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/03-adversarial/fact-checker.md`. **22 verdicts: 13 CONFIRMED, 5 REFUTED, 3 PARTIAL, 1 UNVERIFIED.**

Most-consequential findings:

- **REFUTED (V-15) — Phase 0's three named "load-bearing fixes" are all non-applicable.** journal-remote `--listen-http=19532` is already in HEAD's Dockerfile (the FC NAY #1 fix landed earlier). The UART sed in `rpi-node.pkr.hcl` is already idempotent via `grep -q ... ||` (introduced in commit `a46cc5f`, 2026-05-03, BEFORE the `ee41010` anchor). `configure-eeprom.sh` contains no `rpi-eeprom-update -a` or `PCIE_PROBE=1` — there is nothing to re-order. Phase 0 as written is a no-op except for the ARM-runner migration item.

- **PARTIAL/REFUTED (V-9) — AC-11 overstates what `nvmd/nixos-raspberrypi` produces.** The Pi 5 modules set NVMe initrd kernel modules, the rpi5 kernel package, and `enable_uart=1`, but DO NOT auto-emit `dtparam=nvme`, `dtparam=pciex1_gen=3`, `auto_initramfs=1`, `usb_max_current_enable=1`, or `kernel=kernel_2712.img`. Operator must add these via `hardware.raspberry-pi.config.<board>.options.*` explicitly. Phase 1 gate condition, not plan-killer.

- **PARTIAL (V-6) — sops-nix activation timing.** Does NOT automatically wait for `fileSystems.` mounts. Combined plan must explicitly set `fileSystems."/var/lib/hyperion-id".neededForBoot = true;` for the age key to be available at activation. The "should hold" framing in §F.4 is too soft — without `neededForBoot`, it bites quietly.

- **CONFIRMED (V-3) — load-bearing pivot economics.** `ubuntu-24.04-arm` runners are GA for public repos at no cost since 2025-08-07 per the GitHub blog URL. 4 vCPU. Labels exact. The build-cost lever the pivot rides on survives empirical challenge.

- **CONFIRMED (V-1, V-2, V-14) — flake ecosystem holds up.** `nvmd/nixos-raspberrypi` v1.20260517.0 active (released 6 days before this run). Cachix substituter reachable. `raspberry-pi-nix` archived 2025-03-23 with Pi 5 USB/NVMe listed as not-working — both load-bearing facts hold.

- **CONFIRMED (V-5, V-7, V-22) — NixOS module surface area.** `services.k3s.{tokenFile,serverAddr,role,extraFlags,manifests,environmentFile}` all exist (module path moved to `rancher/`). `services.journald.upload.settings.Upload.URL` exists. tokenFile works with `sops.secrets.<name>.path` (path is string-coerced at build time).

- **CONFIRMED, stronger than claimed (V-8) — Old Man's "1 of 25" empirical observation.** Actual count: **0 of 25** FINAL.md defects committed between `ee41010` and HEAD. Only 2 commits touch `Hyperion/` in that window; both are lint/scope tweaks, neither is from the defect catalog. The §B-1 reasoning is reinforced.

- **PARTIAL (V-4) — NixOS 25.11 EOL hits inside Phase 6 sunset window.** Channel EOLs 2026-06-30; sunset is 2026-08-15. AC-13 mentions "biannual channel bump" but does not name 26.05 as the target during the sunset.

- **PARTIAL (V-16) — Colmena last release v0.4.0 (2023-05-15).** Active commits in 2025, but pin by commit hash, not tag. Watch list.

### Verdict file location

`docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/03-adversarial/fact-checker.md`.

### 2026-05-21T16:50:00Z — Pipeline run `20260521T144651Z-dev-hyperion-flashing-to-heimdall` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260521T144651Z-dev-hyperion-flashing-to-heimdall/iter-1/03-adversarial/fact-checker.md`. **14 CONFIRMED, 1 REFUTED, 3 UNVERIFIED.** Highlights:

- **CONFIRMED — gatewayd ships in `systemd-journal-remote` Debian package.** apt-cache Description: *"This package provides tools for sending and receiving remote journal logs: \* systemd-journal-remote \* systemd-journal-upload \* systemd-journal-gatewayd"*. Trixie filelist confirms `/usr/lib/systemd/systemd-journal-gatewayd`, units, manpages, `browse.html`. IaC's "no new apt install" claim correct.
- **CONFIRMED — gatewayd defaults: port 19531, `/browse` UI, no flags needed for plain HTTP.** Manpage SUPPORTED URLS lists `/boots`, `/browse`, `/entries`, `/machine`, `/fields/_FIELD_`. `/entries` accepts `?follow` (bare, no `=1`) and `?KEY=match` (e.g., `_HOSTNAME`, `_SYSTEMD_UNIT`).
- **CONFIRMED — `nginx:1.30.1-alpine` is current stable.** nginx.org: "Stable: nginx-1.30.1 (released 2026-05-13)". Docker Hub digest pushed 2026-05-20; same digest as `stable-alpine` and `:alpine`. Multi-arch (amd64/arm/v6/v7/arm64/v8/386/ppc64le/riscv64/s390x). Includes CVE fixes for HTTP/2 injection, buffer overflow, HTTP/3 spoofing, UAF.
- **CONFIRMED — rpi-eeprom #629 closed-not-planned (2024-11-07).** #718 STILL OPEN as of 2026-05-21 (opened 2025-06-23, "pi5 second PCIe boot fails", PCIE_PROBE=1 ineffective). No fix in recent release notes (latest v2026.05.11-2712). H4 truth-table row stays valid.
- **CONFIRMED — `ghcr.io/stevengann/homelab-{ci-deploy,journal-remote,healthcheck}` are anonymously pullable and ONLY have `:latest`.** Registry tags/list returns `["latest"]` for all three. IaC's risk flag survives challenge.
- **CONFIRMED — Caddy auto-disables buffering for `Content-Type: text/event-stream`.** No `flush_interval -1` needed for SSE specifically; the directive exists but is unnecessary when the upstream sets the correct content-type header. Means a future Caddy front for gatewayd is one-line clean.
- **CONFIRMED — both Packer-image workflows path-filter the planned edits.** `build-bootstrap-img.yml` matches `Hyperion/packer/files/bootstrap.sh` and `rpi-bootstrap.pkr.hcl`. `build-node-img.yml` matches `rpi-node.pkr.hcl` and `Hyperion/packer/files/**`. All three planned edits trigger CI.
- **CONFIRMED — `Akasha/k3s-control-plane/journal-remote/Dockerfile` shape matches the draft.** `FROM debian:trixie-slim` + apt install systemd-journal-remote + `USER systemd-journal-remote` + exec-form ENTRYPOINT. No CMD. Replacement entrypoint is mechanically clean.
- **CONFIRMED — `bootstrap.sh:138-161` `set_status` heredoc is trivially extensible.** Adding `AKASHA_BASE` and `nvme_version` is 2 lines; consumers parse JSON, so additive fields don't break.

- **REFUTED — `watch-flash.sh`'s gatewayd URL `?output=json-sse` is not a documented query parameter.** gatewayd format selection is via `Accept:` header (text/plain, application/json, text/event-stream, application/vnd.fdo.journal). One-line fix in §3.7: use `curl -sN -H 'Accept: text/event-stream' …?follow&_HOSTNAME=…&_SYSTEMD_UNIT=…`. Otherwise the script gets default format, not SSE.

- **UNVERIFIED — Caddy auto-flush behavior under mixed Content-Type responses through one reverse_proxy.** Single Content-Type sniffing per response should handle it but no explicit confirmation in docs. Not load-bearing for v1 (draft defers Caddy front).
- **UNVERIFIED — Whether `entrypoint.sh` wrapper can run both `systemd-journal-remote` AND `systemd-journal-gatewayd` under `USER systemd-journal-remote`.** Existing Dockerfile drops to that UID before ENTRYPOINT. Gatewayd typically runs as `systemd-journal-gateway` per its package unit file. May work via journal-read access on the bind-mount; pre-deploy smoke-test catches.
- **UNVERIFIED — Caddy auto-flush for `application/vnd.fdo.journal`.** Not in v1 scope.

- **New fact — Caddy's content-type-based SSE auto-disable is documented** (`reverse_proxy` directive page). Caddy isn't an obstacle to fronting gatewayd; the only risk is mixed-format responses through a single block.
- **New fact — `AKASHA_BASE` variable name is becoming misleading post-cutover.** Editorial: revision could rename to `IMG_BASE` (same CI rebuild trigger).
- **New fact — Akasha's ci-deploy healthcheck uses jq+date arithmetic** (verifies last_poll < 15 min). Draft's `test -f` simplification loses that check; intentional separation-of-concerns is fine if explicitly noted.

### 2026-05-17T22:30:00Z — Pipeline run `20260517T213331Z-dev-heimdall-finalize` iter-1, combined-draft adversarial review

Ledger written to `docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/03-adversarial/fact-checker.md`. **19 CONFIRMED, 3 REFUTED, 4 UNVERIFIED.** Highlights:

- **CONFIRMED** — `technitium/dns-server:15.2.0` is current stable, multi-arch (amd64/arm64/armv7), and the in-container config path IS `/etc/dns`. `ghcr.io/moghtech/komodo-{core,periphery}:2.2.0` exist with `:2` tracking `:2.2.0`. `setup-periphery.py` accepts `--version` and `v2.2.0` is a valid tag; installs to `/usr/local/bin/periphery`, `/etc/komodo/periphery.config.toml`, `/etc/systemd/system/periphery.service`. `mongo:7.0` multi-arch, `--wiredTigerCacheSizeGB 0.25` valid (minimum). Caddy `tls internal` exists, internal CA stored at storage-key `pki/authorities/local/root.crt` (Docker data dir `/data`). Technitium env vars apply only on first start (config file does not exist). `gh release view -R … --json tagName -q .tagName` returns latest's tag as raw string. Hyperion MetalLB file list / Akasha k3s server `command: server` / `k3s-agent.yml` line 38 `when:` guard all match repo.

- **REFUTED #1** — Phase 2 step 4 Periphery onboarding flow is mechanically wrong. Draft has operator pasting a Core public key into `core_public_keys`. v2 actually uses an *onboarding key* (one-time TOFU credential minted by Core, consumed by Periphery via `--onboarding-key` flag or `onboarding_key = "..."` in TOML). Periphery generates its own keypair and sends just the public key to Core during first handshake. No `core_public_keys` line gets manually edited.

- **REFUTED #2** — Phase 1 step 10's "Periphery comes up unattached (no `core_public_keys` in config yet)" framing implies a workflow that doesn't exist. The Core public key never goes into the Periphery TOML at all; it's exchanged at the Noise layer and stored in the Periphery's keys directory.

- **REFUTED #3** — `KOMODO_INIT_ADMIN_USERNAME/PASSWORD` env-var names unverified against `core.config.toml` upstream; flagged as needing exact citation in the revision since they're load-bearing in the SOPS env list.

- **UNVERIFIED #1** — The Caddyfile `:80 handle /ca.crt file_server` shorthand hides a real implementation gap. `file_server` serves from a *directory*, not a single file. Real form needs `rewrite * /root.crt` + `file_server { root /data/caddy/pki/authorities/local }`. Revision should spell it out.

- **UNVERIFIED #2** — "Under 256 MB combined Komodo+Mongo footprint" is not in primary sources; realistic minimum is ~0.5 GB. Cap at WiredTiger 256 MB only restricts mongod's cache, not the aggregate process RSS.

- **UNVERIFIED #3 & #4** — Komodo UI exact button labels ("Generate Onboarding Key") and the Hyperion ansible re-install task design (existing `args.creates: /usr/local/bin/k3s` will short-circuit any re-run regardless of `when:` — revision must say whether the new task is separate or removes the creates).

- **New fact surfaced** — Komodo Core `:latest` on GHCR does NOT point at `:2.2.0`'s digest (or any `2.x.y` stable digest). It tracks a `*-dev` build. Pinning to `:2.2.0` is strictly necessary; `:latest` is actively harmful, not just deprecated.

- **New fact surfaced** — `setup-periphery.py` only `systemctl start`s, never `systemctl enable`s; the draft's `enable --now` is necessary for reboot survival. And the script skips writing config if `/etc/komodo/periphery.config.toml` exists, so the draft's `install -m 0640` over-write step interacts subtly with re-runs — revision should choose one ownership pattern.

- **New fact surfaced** — k3s `--disable=servicelb` is server-only-required; the agent-side `INSTALL_K3S_EXEC` in the draft is belt-and-suspenders, not load-bearing. Disabling on the Akasha server uninstalls the cluster-wide DaemonSet.

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

- **New fact A surfaced** — **The Pi Expert's archived ServiceLB-vs-MetalLB latent-conflict claim is empirically grounded.** `Hyperion/ansible/k3s-agent.yml:32-38` installs k3s with no `INSTALL_K3S_EXEC` flag → ServiceLB enabled on every agent. `Akasha/k3s-control-plane/docker-compose.yml:4` runs `command: server` with no `--disable=servicelb,traefik`. Heimdall's contract "Caddy → stable MetalLB VIP" is undefined while ServiceLB also races to fulfill `Service type=LoadBalancer`. Criterion 6 ("reconstruct from scratch using only this repo") cannot be honestly claimed until Hyperion is fixed. This is the most important finding of the run beyond the four required edits.

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

### nixos-identity-usb verification (2026-05-23 run)

- **`nvmd/nixos-raspberrypi` repo/releases/issues** —
  `https://api.github.com/repos/nvmd/nixos-raspberrypi` and
  `.../releases`, `.../issues/{117,159}`, plus
  `https://github.com/nvmd/nixos-raspberrypi/blob/develop/README.md`. Accessed
  2026-05-23. Confidence: official.
- **`nix-community/raspberry-pi-nix` README** —
  `https://github.com/nix-community/raspberry-pi-nix`. Accessed 2026-05-23.
  Confidence: official (project itself).
- **GitHub Actions ARM runner GA announcement** —
  `https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/`. Accessed 2026-05-23. Confidence: official (GitHub).
- **NixOS 25.11 release notes** —
  `https://nixos.org/blog/announcements/`. Accessed 2026-05-23. Confidence:
  official.
- **NixOS k3s module @ release-25.11** —
  `repos/NixOS/nixpkgs/contents/nixos/modules/services/cluster/rancher/{default.nix,k3s.nix}?ref=release-25.11`. Accessed via `gh api` 2026-05-23. Confidence: official (nixpkgs source).
- **NixOS journald-upload module @ release-25.11** —
  `repos/NixOS/nixpkgs/contents/nixos/modules/system/boot/systemd/journald-upload.nix?ref=release-25.11`. Accessed via `gh api` 2026-05-23.
- **sops-nix activation docs** —
  `https://github.com/Mic92/sops-nix/blob/master/README.md`. Accessed
  2026-05-23. Confidence: official.
- **Colmena releases/commits + features/keys docs** —
  `https://api.github.com/repos/zhaofengli/colmena/{releases,commits}` and
  `https://colmena.cli.rs/unstable/features/keys.html`. Accessed 2026-05-23.
- **rpi-eeprom firmware-2712 release notes** —
  `https://raw.githubusercontent.com/raspberrypi/rpi-eeprom/master/firmware-2712/release-notes.md`. Accessed 2026-05-23.
- **rpi-eeprom issues #629/#718** —
  `https://github.com/raspberrypi/rpi-eeprom/issues/{629,718}`. Accessed
  2026-05-23.
- **Cachix substituter operational** — `curl
  https://nixos-raspberrypi.cachix.org/nix-cache-info` returned valid
  `StoreDir: /nix/store / WantMassQuery: 1 / Priority: 41`. Accessed
  2026-05-23.

### Hyperion-flashing-to-Heimdall verification (2026-05-21 run)

- **Debian/Ubuntu `systemd-journal-remote` package metadata** — `apt-cache show systemd-journal-remote` output on local workstation (Ubuntu archive entries 255.4-1ubuntu8.14/15); Description enumerates all three binaries shipped. Confidence: official.
- **Debian Trixie `systemd-journal-remote` filelist** — `https://packages.debian.org/trixie/amd64/systemd-journal-remote/filelist`. Accessed 2026-05-21. Confidence: official. Confirms `/usr/lib/systemd/systemd-journal-gatewayd` + browse.html shipped in same .deb.
- **systemd-journal-gatewayd.service(8) manpage (Debian Trixie)** — `https://manpages.debian.org/trixie/systemd-journal-remote/systemd-journal-gatewayd.service.8.en.html`. Accessed 2026-05-21. Confidence: official. Documents `/entries?follow&KEY=match`, Accept-header format selection, default port 19531, `/browse` UI.
- **Docker Hub `library/nginx:1.30.1-alpine` manifest** — `https://hub.docker.com/v2/repositories/library/nginx/tags/1.30.1-alpine/`. Accessed 2026-05-21. Confidence: official registry. Digest `sha256:c819f83c54b0…`, pushed 2026-05-20, multi-arch.
- **nginx.org homepage release table** — `https://nginx.org/`. Accessed 2026-05-21. Confidence: official. Stable: 1.30.1 (2026-05-13). Mainline: 1.31.0 (2026-05-13).
- **rpi-eeprom GitHub issues #629 / #718** — `https://github.com/raspberrypi/rpi-eeprom/issues/{629,718}`. Accessed 2026-05-21. Confidence: official upstream tracker. #629 closed-not-planned (2024-11), #718 open (2025-06-23 → 2026-05).
- **rpi-eeprom releases** — `https://github.com/raspberrypi/rpi-eeprom/releases`. Accessed 2026-05-21. Confidence: official. Latest v2026.05.11-2712; no PCIe re-enumeration fixes in last 12 months of notes.
- **GHCR registry API for `stevengann/homelab-{ci-deploy,journal-remote,healthcheck}`** — `https://ghcr.io/v2/stevengann/homelab-{…}/tags/list` with anonymous bearer token. Accessed 2026-05-21. Confidence: official registry. All three return `["latest"]` only.
- **Caddy `reverse_proxy` directive docs** — `https://caddyserver.com/docs/caddyfile/directives/reverse_proxy`. Accessed 2026-05-21. Confidence: official. Quote: `flush_interval` ignored for `Content-Type: text/event-stream`; explicit `-1` disables buffering.
- **`Akasha/k3s-control-plane/journal-remote/Dockerfile`** — direct read in repo. Confirms `FROM debian:trixie-slim`, apt install systemd-journal-remote, `USER systemd-journal-remote`, exec-form ENTRYPOINT, no CMD.
- **`.github/workflows/build-{bootstrap,node}-img.yml`** — direct read in repo. Path filters confirmed to catch all three planned edits in §3.6.
- **`Hyperion/packer/files/bootstrap.sh` lines 32, 138-232** — direct read in repo. Confirms `set_status` heredoc structure, `AKASHA_BASE` scope, Python HTTP server serves file verbatim.

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
