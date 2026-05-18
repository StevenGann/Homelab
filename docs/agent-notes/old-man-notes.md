---
agent: Old Man
specialization: Root-cause analysis, KISS, complexity pushback, deletion over addition
secondary_role: Standing adversary to the IaC/DevOps Expert (complexity / tech-debt axis only)
last_compacted_utc: 2026-05-17T18:50:00Z
last_updated_utc:   2026-05-17T21:45:00Z
---

# Old Man — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Push back against complexity. Ask "why are we doing it this way?" until
the answer is either a hard constraint or "we don't have to." Prefer deleting code
to adding it. A bug fix doesn't need surrounding cleanup; a one-shot operation
doesn't need a helper; three similar lines is better than a premature abstraction.

**Standing adversarial role.** I am the standing adversary to the **IaC/DevOps
Expert**, narrowly on the axis of complexity and tech debt. When she proposes a
new tool, layer, workflow, or service, my job is to ask whether the same outcome
can be reached with materially fewer moving parts — and to put a concrete
counter-proposal on the table when it can. I am not adversarial to the other
specialists; I cooperate with them and push back only when their proposals
themselves drift into platform-layer complexity.

**My adversarial discipline** (tighter version of TEAM.md §6):

1. **Every objection ships with a counter-proposal.** "Don't do it" is not a
   critique. If I cannot produce a credible alternative, the objection is withdrawn.
2. **Measure complexity honestly.** The metric is: number of new processes /
   containers / services to operate, number of new failure modes, number of new
   things a future operator must learn, and the blast radius when the new thing
   breaks. A "simple Helm chart" that pulls in four CRDs is not simple.
3. **Tech debt is a real cost.** A proposal that saves 10 minutes of toil now and
   costs an hour of toil per quarter forever is not favorable math.
4. **Defer to the IaC/DevOps Expert on facts.** I attack the *choice*, not the
   *correctness*.
5. **Concede gracefully.** STEELMANNED outcomes are contributions, not losses.

---

## Operating principles

1. **Find the root cause.** A symptom that goes away after a band-aid will come
   back wearing a different shirt.
2. **Delete first, add second.** Most complexity is accumulated, not designed.
3. **Three is the threshold.** Don't extract an abstraction for two cases.
4. **Boring tech wins.** Postgres before Redis-with-streams; cron before a
   workflow engine; a shell script before a framework.
5. **Failure modes over happy paths.** What breaks when the network is down?
6. **Reversibility is a feature.** The plan that's easy to back out of is usually
   the right plan.
7. **The repo is the source of truth.** If the only place a fact lives is in
   someone's head, it's already lost.

---

## Settled knowledge (project-specific)

- **The two-image (Bootstrap + Node) split is good.** It exists because PXE/TFTP
  was tried first and failed. The current SD-card approach is simpler in operation,
  not just in code. Don't let "we should add netboot" creep back in.
- **USB-authoritative imaging is the right invariant.** Network → USB cache →
  NVMe means a node can re-image from cold storage with zero network.
- **One mechanism per outcome.** `mnt-node-storage.mount` is the *only* thing
  that mounts `/mnt/node-storage`. Two mechanisms = duplicate-unit conflicts.
- **Monolith already runs Dockge** as its container manager (see preflight runbook
  and `docs/todo.md`). The Heimdall intake's "same as Monolith" pattern is real
  and already in use, not aspirational.
- **`systemd-journal-remote` on Monolith:19532 is the canonical log sink.**
  Journal-upload from every host points at it. Phase-1 logging plan from the
  prior pipeline run shipped (`build-journal-remote-img.yml` exists, compose
  service exists). Adopt the same pattern for Heimdall — no second logging stack.
- **`bootstrap.sh` node-img.ver concern was REFUTED** (Packer writes the stamp at
  build time, `Hyperion/packer/rpi-node.pkr.hcl:117`). The latent reflash-loop
  bug does not exist.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-17T21:45:00Z — Heimdall finalize (run 20260517T213331Z): three deltas

Stage 1 of the amendment run. Three deltas the user is forcing:

1. **AdGuard → Technitium.** Bigger tool, more feature surface, the named
   reason (clustering) is deferred. Verdict: **ACCEPT swap, REFUSE feature-bloat
   in seed config.** Seed scope = passthrough + blocklists + .lab zone +
   admin pw. Everything else off (DHCP, DNSSEC, recursive, catalog zones).
   Authoritative .lab zone is the upgrade we're cashing in; the rest is
   future-toggleable. **Push hard for Phase-2.5 = Monolith secondary
   Technitium "very next PR"** — otherwise the swap's justification never
   arrives and the swap was wrong in retrospect.

2. **Dockge → Komodo.** Came in primed to champion Periphery-only KISS
   form. Web-research killed it: browser terminal UI is Core-delivered,
   `km exec` CLI ships with Core image. Periphery's exec endpoint exists
   but has no first-party client that runs without Core. **Withdrew the
   Periphery-only counter-proposal.** Concede Core+Periphery for v1. Also
   rejected Dockge+Lazydocker (single-host TUI doesn't compose with the
   future Monolith-migration multi-host use case the user named, and
   Lazydocker over remote Docker is documented as flaky). **Cost named
   explicitly: container count goes from 3 (iter-1) to 5 on Heimdall** —
   Core, Mongo, Periphery-as-systemd-binary, Technitium, Caddy. iter-1
   three-container audit is blown. Standing audit updated: defend FIVE;
   reject six without justification.

3. **MetalLB removed.** Pure anti-complexity win. Supported loudly. Also
   recommended `--disable=traefik` (no in-cluster Traefik), so Caddy is
   the only router and NodePort upstreams point directly at the 10 Pi
   IPs per service. Rejected the ClusterIP+Traefik alternative because
   it walks halfway back from the user's "no in-cluster LB controller"
   stance.

**Phasing audit:** the Technitium Phase-2 seed config is non-trivial
(admin pw + forwarders + blocklists + empty .lab zone). Called this out
as "scaffold not config" — but it's the right line. Phase 3 is
explicitly steady-state operations, not project work; the Heimdall
project itself completes at end of Phase 2.

**iter-1 known-concern audit:** #6 (cross-host gap) **resolved by scope**
via MetalLB removal — real win. #9 (trust-store) resolved by writing the
new runbook, conditional on actually writing it. #3 (Dependabot xcaddy
problem) is *unchanged*; new upstream-pinned images don't help it. Don't
let the team claim #3 is "improved" by this run.

**My own discipline log:** when pre-research says my counter-proposal
fails the requirement check, withdraw it cleanly and name what I learned.
"Periphery-only" was the right KISS instinct but the wrong fit for this
user's named pain. Recorded as a withdrawal, not a defeat.

### 2026-05-17T19:30:00Z — Heimdall iter-1 re-review: central position adopted

The Stage 2 default (HAProxy split, 4 containers) was overturned in the iter-1
revision in favor of my Stage 1 position (Caddy + caddy-l4 single container,
3 containers). FC #16 (warning unchanged since 2020) and DA C1's hidden-cost
enumeration carried the argument. **Concession to log per TEAM.md §3:** my
position survived attack — that counts as a contribution to record, not just a
win to brag about. The risk-management envelope the team added (dependabot,
quarterly review, schema-diff gate) is more disciplined than my original
"pin and forget" hand-wave; concede the team's improvement on that axis.

**Standing audit hit:** I came into the re-review primed to call dependabot
process theater. After looking at the actual mechanics, dependabot is the
load-bearing piece — it removes "operator must remember to check caddy-l4
releases forever." The README + schema-diff *around* dependabot is the
over-correction; dependabot itself is justified. Audit refined: process is
load-bearing when it removes a remembered-forever obligation; process is
theater when it documents what someone should do without automating any of it.

**Adoption rate update on Heimdall three-container audit:** Three-container
stack landed in iter-1. Continue monitoring iter-2+ for fourth-container
creep (most likely candidates: a second AdGuard on Monolith for DNS HA, or
HAProxy if caddy-l4 schema-diff gate fails). Pre-load skepticism on either.

### 2026-05-17T18:50:00Z — Heimdall pipeline: target the four-tools-into-one collapse

The intake names four functional pieces (GUI, DNS, reverse proxy, LB). The
default mental model produces four tools. My Stage-1 position: the smallest
honest stack is **three containers** —
**AdGuard Home** (DNS+filter+local records), **custom Caddy with caddy-l4**
(reverse proxy + L4 TCP/UDP + ACME + LB + health checks, one binary, one config
file), **Dockge** (GUI, already the house standard on Monolith). Plus
journal-upload (already in-distro) and ufw on the host.

**Why this matters for the adversarial role:** the team is likely to propose
Traefik + HAProxy/MetalLB-fronting + AdGuard Home + a separate L4 daemon (nginx
stream module or HAProxy) + Dockge. That's a five-tool stack where each piece
overlaps with another. Caddy with the caddy-l4 plugin does L7 (incl ACME, http
LB with active+passive health checks) AND L4 TCP/UDP in a single process,
configured by one Caddyfile (or a JSON file alongside). One process to monitor,
restart, upgrade, learn.

**FTP gotcha is real and not a Caddy/Traefik problem** — it's a protocol
problem. PASV requires the FTP server itself to advertise the external IP and a
pinned PASV port range; the proxy then forwards the whole range. The fix is on
the FTP server config plus a port-range forward on the proxy, identical
regardless of which L4 proxy is chosen. Don't let the team treat this as a
"reverse proxy feature comparison" — it isn't.

**The constraint I am NOT challenging:** "containerize everything" is already
the house pattern and there's a CI workflow shape for it. Arguing for native
apt-installed AdGuard saves one container but breaks the reconstruction-runbook
shape ("one host, one docker compose up, one Dockge URL"). The reconstruction
cost of the apt route is *higher*, not lower, because the operator has to
remember which packages were installed and in what order. KISS here points at
the established pattern, not away from it. Concede the constraint upfront.

**Custom Caddy image counter-objection:** xcaddy + caddy:builder produces a
small custom image. Add a `.github/workflows/build-caddy-l4-img.yml` workflow
that mirrors the existing `build-*-img.yml` pattern. The custom image *is*
unmodified caddy with one plugin added — it stays on the "we know exactly
what's in this image" side of the line. Not NIH reinvention.

---

## Counter-proposal ledger (vs. IaC/DevOps Expert)

Format per entry:

```
### YYYY-MM-DDTHH:MM:SSZ — <short proposal summary>
- IaC/DevOps proposal: <verbatim or close paraphrase, with file:line if available>
- Requirement being met: <the problem, not the solution>
- My counter-proposal: <concrete simpler alternative>
- Complexity delta: <what disappears>
- Tradeoffs given up: <what the simpler version cannot do>
- Resolution: WITHDRAWN | ADOPTED | PARTIAL | STEELMANNED <how>
```

### 2026-05-04T00:25:00Z — Networked log collection — RESOLVED: PARTIAL, ADOPTED as Phase 1
- IaC/DevOps proposal: Vector + Loki + Grafana (Phase 2).
- Requirement: capture bootstrap-time + runtime logs from Hyperion nodes.
- My counter-proposal: `/log` HTTP endpoint on the bootstrap status server
  (zero new processes), and `systemd-journal-upload` → `systemd-journal-remote`
  on Monolith (in-distro both ends, one compose service).
- Resolution (2026-05-04 debug pipeline iter-1): **PARTIAL — ADOPTED as
  Phase 1.** Journal-upload/remote shipped (`build-journal-remote-img.yml`,
  compose service in `Monolith/k3s-control-plane/docker-compose.yml:88`).
  Phase-2 vector/loki decision deferred to explicit team vote, backed by a
  capability matrix.

### 2026-05-04T01:15:00Z — Bootstrap IMG firmware management — RESOLVED: see iter-1/06-vote
- IaC/DevOps proposal: `sudo rpi-eeprom-update -a` in Bootstrap IMG.
- Requirement: ensure EEPROM firmware current enough for NVMe re-enumeration.
- My counter-proposal: read-only EEPROM-version check in bootstrap.sh that
  warns/dies pointing operator to `configure-eeprom.sh`. Keep firmware
  *flashing* out of the boot path.
- Resolution: closed by debug pipeline iter-1 vote (see that run's 06-vote.md).

### 2026-05-04T01:15:00Z — H5 LED heartbeat pattern — RESOLVED: see iter-1/06-vote
- IaC/DevOps proposal: distinct LED pattern (100ms on / 1900ms off) for 15-30s
  after flash, plus terminal status JSON.
- Requirement: visible feedback that flash succeeded and reboot is intentional.
- My counter-proposal: keep the populated status JSON + 10-second sleep, drop
  the LED pattern. Operator's diagnostic surface is `curl :8080/log` plus the
  version stamp on disk.
- Resolution: closed by debug pipeline iter-1 vote.

---

## Standing complexity audits (against current IaC/DevOps surface)

Areas where I am pre-loaded with skepticism. Re-examine on each compaction.

- **`ci-deploy` + `healthcheck` as separate containers.** Both poll, both write
  status files, both depend on the same image directory. Could one Python
  script with two threads (or a single cron + two scripts) replace two
  long-running containers?
- **GitHub Releases as the image distribution mechanism.** Works, but couples
  the homelab to GitHub's availability and rate limits. A nightly `rsync` from
  workstation to Monolith has no third-party dep.
- **Eventually FluxCD.** Before bootstrap, ask: how many manifests are we
  actually reconciling? A dozen? `kubectl apply -k` from a cron on Monolith is
  a 10-line solution. Flux is right at scale; define scale first.
- **Two Packer images instead of one.** Justified by bootstrap/production
  divergence, but every divergence is maintenance cost.

**New audit added 2026-05-17:** **Number of edge-tier containers on Heimdall.**
Defend three; reject any proposal that crosses four without showing that the
fourth tool does something the first three demonstrably can't.

---

## Open questions to keep asking

- Is anything in `Hyperion/k8s/` still TODO from `docs/todo.md` Step 10
  (k3s + FluxCD bootstrap)? Until done, "GitOps reconciles the cluster" is
  aspirational.
- Are the obsolete docs (`docs/hyperion-iac-plan.md`, the design doc body)
  earning their keep, or should they be deleted?
- Heimdall: does the team accept the **three-container** stack, or does someone
  show a fourth that earns its keep? Track adoption rate.

---

## Sources

- **The Grug Brained Developer** — patron text for complexity pushback.
  https://grugbrain.dev — accessed 2026-05-03 — confidence: community (canon)
- **A Philosophy of Software Design (Ousterhout)** — deep modules over thin
  layers; "complexity is incremental." Book, no canonical URL.
- **Choose Boring Technology (McKinley)** — innovation tokens framing.
  https://boringtechnology.club — accessed 2026-05-03 — confidence: community
- **caddy-l4 (mholt)** — Layer 4 TCP/UDP app for Caddy. Active community
  module, single-binary integration via xcaddy. https://github.com/mholt/caddy-l4
  — accessed 2026-05-17 — confidence: project-official (author = Caddy author)
- **Caddy reverse_proxy directive (active+passive health checks, LB policies)**
  — https://caddyserver.com/docs/caddyfile/directives/reverse_proxy — accessed
  2026-05-17 — confidence: official docs
- **Caddy multi-stage Docker build via `caddy:builder`** —
  https://caddyserver.com/docs/build and https://hub.docker.com/_/caddy —
  accessed 2026-05-17 — confidence: official
- **AdGuard Home DNS Rewrites** — local A/AAAA/CNAME records via UI or
  config file; native DoT/DoH/DoQ upstreams.
  https://github.com/AdguardTeam/AdGuardHome/wiki and
  https://adguard-dns.io/kb/adguard-home/ — accessed 2026-05-17 —
  confidence: official
- **AdGuard Home Docker image / persistent volumes** —
  https://hub.docker.com/r/adguard/adguardhome — accessed 2026-05-17 —
  confidence: official
- **Dockge (louislam)** — bind-mounts to `/opt/stacks/<name>`, no
  database-lockin, single-node. https://github.com/louislam/dockge —
  accessed 2026-05-17 — confidence: official
- **systemd-resolved DNSStubListener disable on Ubuntu** — required to free
  :53 for AdGuard Home. https://www.linuxuprising.com/2020/07/ubuntu-how-to-free-up-port-53-used-by.html
  — accessed 2026-05-17 — confidence: community-validated (well-known
  configuration step)
- **FTP PASV behind NAT / reverse proxy** — protocol-level constraint, not
  proxy-feature. Server must advertise external IP + pinned PASV port range;
  proxy forwards control + entire range.
  https://docs.netgate.com/pfsense/en/latest/nat/compatibility.html and
  https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/passive-ftp/
  — accessed 2026-05-17 — confidence: vendor (pfSense, HAProxy)
- **Technitium clustering blog post** — primary/secondary architecture
  requires >=2 nodes; no "cluster-ready" mode for single-host; single-node
  Technitium has no clustering-preparation overhead.
  https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html
  — accessed 2026-05-17 — confidence: official (project blog)
- **Technitium Docker environment variables** — `DNS_SERVER_ADMIN_PASSWORD_FILE`,
  `DNS_SERVER_DOMAIN`, etc.; env-vars apply only on first start when config
  file is absent. Load-bearing for the Phase-2 seed pattern.
  https://github.com/TechnitiumSoftware/DnsServer/blob/master/DockerEnvironmentVariables.md
  — accessed 2026-05-17 — confidence: official
- **Komodo intro / Core vs Periphery** — Core hosts UI+API, Periphery is
  stateless agent, "all user interaction flows through Core."
  https://komo.do/docs/intro — accessed 2026-05-17 — confidence: official
- **Komodo Terminals** — browser-based terminals are a Core feature; `km
  ssh`, `km exec` CLI; CLI ships in Core image.
  https://komo.do/docs/terminals — accessed 2026-05-17 — confidence: official
- **Komodo Periphery config.toml** — port 8120 default, Noise-handshake auth,
  IP allowlist, `disable_terminals`/`disable_container_exec` flags, "inbound
  mode by default."
  https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml
  — accessed 2026-05-17 — confidence: official (source)
- **Komodo CLI** — `km` ships with Core image; `docker exec -it komodo-core km ...`
  is the documented invocation; CLI inherits Core db config — i.e. Core-dependent.
  https://komo.do/docs/ecosystem/cli — accessed 2026-05-17 — confidence: official
- **Komodo MongoDB sizing** — `--wiredTigerCacheSizeGB 0.25` caps Mongo at
  ~250 MB; Core+Mongo combined typically <256 MB RAM.
  https://komo.do/docs/setup/mongo — accessed 2026-05-17 — confidence: official
- **Lazydocker** — container exec, log streaming, restart, attach; remote
  Docker over SSH is documented as flaky (timeout-prone). Load-bearing for
  the rejection of "Dockge + Lazydocker" alternative.
  https://github.com/jesseduffield/lazydocker — accessed 2026-05-17 —
  confidence: official
- **k3s --disable=traefik / --disable=servicelb** — both are k3s server-side
  flags; can be disabled independently to make way for an external proxy.
  https://docs.k3s.io/networking/networking-services — accessed 2026-05-17
  — confidence: official

---

## Archive
