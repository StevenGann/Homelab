---
agent: Old Man
specialization: Root-cause analysis, KISS, complexity pushback, deletion over addition
secondary_role: Standing adversary to the IaC/DevOps Expert (complexity / tech-debt axis only)
last_compacted_utc: 2026-05-21T15:00:00Z
last_updated_utc:   2026-05-23T07:30:00Z
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

- **The two-image (Bootstrap + Node) split is good _given a re-flash loop that
  produces working nodes_.** Re-examined 2026-05-23 (twice). First revision:
  justified because Node IMG had to be redistributable as a block image. Second
  revision (after user correction 00b in run 20260523T050133Z): the split
  presupposes the re-flash *mechanism* works. 00b establishes that the
  mechanism does not produce a working node end-to-end despite many attempts.
  The split is therefore now justified only as a historical artifact, not as a
  live invariant. Under any successor architecture (C = NixOS pivot, D =
  workstation `dd` of upstream Ubuntu, or other), the split is dropped or
  redefined. Don't let "we should add netboot" creep back in either way.
- **USB-authoritative imaging is the right invariant — _but the invariant is
  about identity, not OS bits, and is independent of whether on-Pi reflash
  works_.** Re-examined 2026-05-23 (twice). First revision: load-bearing
  property is hardware swap = move USB stick + update DHCP, power on. Second
  revision (post-00b): this invariant survives the user correction because it
  is a property of *identity portability*, not of *reflash mechanism*. Under
  Counter-C, identity USB carries hostname+labels+secrets+age-key. Under
  Counter-D (workstation `dd` of upstream Ubuntu, named only — not promoted),
  identity USB carries hostname+secrets+Ansible-vars. Both honor the
  invariant. The invariant is the durable thing; the reflash mechanism is not.
- **One mechanism per outcome.** `mnt-node-storage.mount` is the *only* thing
  that mounts `/mnt/node-storage`. Two mechanisms = duplicate-unit conflicts.
- **Akasha already runs Dockge** as its container manager (see preflight runbook
  and `docs/todo.md`). The Heimdall intake's "same as Akasha" pattern is real
  and already in use, not aspirational.
- **`systemd-journal-remote` on Akasha:19532 is the canonical log sink.**
  Journal-upload from every host points at it. Phase-1 logging plan from the
  prior pipeline run shipped (`build-journal-remote-img.yml` exists, compose
  service exists). Adopt the same pattern for Heimdall — no second logging stack.
- **`bootstrap.sh` node-img.ver concern was REFUTED** (Packer writes the stamp at
  build time, `Hyperion/packer/rpi-node.pkr.hcl:117`). The latent reflash-loop
  bug does not exist.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-21T15:00:00Z — Hyperion-flashing-to-Heimdall (run 20260521T144651Z): NO-MIGRATION counter-proposal

Stage 1 of `dev-hyperion-flashing-to-heimdall`. The intake asks for two things
stacked together: (a) migrate three Akasha services (nginx + ci-deploy +
journal-remote) to Heimdall "temporarily", (b) build a realtime monitoring
tool to debug the SSD-not-flashing bug. My position: **(b) alone meets the
actual goal; (a) is yak-shaving that aggravates 3 of 10 unresolved Heimdall
finalize punch-list items.**

**Counter-proposal: `watch-flash.sh` — ~80-line Bash script on the workstation
that polls each Pi's existing `:8080/` JSON + `:8080/log` endpoints in a
loop.** The instrumentation is already in `bootstrap.sh` lines 130–232
(`set_status` + Python `http.server`). Zero new services. No IMG rebuilds.
No cutover. Half a day of work vs ~1–2 weeks for the full migration.

**Cost-of-migration enumerated** (defended in proposal):
- Heimdall container count blows past finalize FINAL.md's "five things"
  ceiling: 4 → 7 (60% violation).
- Both Bootstrap IMG and Node IMG carry `192.168.10.247` baked in
  (`rpi-bootstrap.pkr.hcl:131`, `rpi-node.pkr.hcl:245`,
  `bootstrap.sh:32`). Every move requires CI rebuild of both
  (~25 min each, fragile QEMU ARM64 builds).
- 10 identity USBs need cache invalidation across the cluster.
- Heimdall has "default disk layout, no swap on ZFS" per
  `Heimdall/docs/manual/03-deployment.md` — single-disk SPOF
  for image storage vs Akasha's TrueNAS pool.
- "Temporarily" → double cutover cost with no decision criterion for
  when to revert. Argue: don't move what you'll move back.
- Stacks a second cross-host PR on top of the still-outstanding
  MetalLB-removal cross-host PR from finalize run.

**Middle-ground alternative considered (steelmanned, then rejected):** move
ONLY nginx; keep ci-deploy on Akasha pushing via rsync/NFS to Heimdall.
20% ceiling violation instead of 60%. Still rejected because **even this
delivers zero debug-latency improvement for the SSD-not-flashing bug** —
the debug surface is :8080 on the Pi, not the server side.

**`:8080` 404-is-not-diagnostic caveat is load-bearing** — `debug-flashing.md`
critical-reframe section explicitly calls this out (the cleanup() trap kills
the server on every exit path). The realtime tool must inherit this nuance,
not reproduce the trap. Documented in the proposal as the only non-obvious
design choice for `watch-flash.sh`.

**Self-discipline check** (per TEAM.md §6): my counter-proposal ships with
a concrete alternative, not a "don't do it" rant. Two named alternatives:
the maximalist migration (rejected) and the minimal-migration middle ground
(rejected but steelmanned with explicit fallback condition — Phase B
re-evaluation if Phase A insufficient). Conceded one possibility: if the
user explicitly wants a web UI not a terminal script, KISS-counter dies on
contact; intake says "ONE command or ONE URL" — terminal script IS one
command.

### 2026-05-23T05:01:33Z — Hyperion NixOS-pivot Stage 1: A/B/C ledger, headline = B

**Git-archaeology finding (load-bearing for this entire pipeline).**
`git log ee41010..HEAD -- Hyperion/` shows exactly **two** commits to Hyperion
since the dbg-nvme-not-flashing FINAL.md landed on May 4: `ee41010` (the
single Linux M-1 fix — write `node-img.ver` post-flash) and `ba4185b`
(shellcheck CI). One out of ~25 enumerated implementation defects landed.
The other ~24 (UART sed bug, journal-remote apt-at-start, EEPROM step
ordering, `dtparam=pciex1_gen=3` cross-link, `Trust=` for HTTP journal-upload,
`SystemMaxUse=` cap, healthcheck HTTP vs SSH, disk-usage monitoring, etc.)
were never landed. Repo focus pivoted entirely to Heimdall after May 4
(see the long chain of `heimdall:` commits). **The user's "quagmire" is not
a problem with the architecture; it's that the debug pipeline produced a
plan and the operator didn't execute it.** The pivot to NixOS, in the most
honest framing, is the user wanting a clean reset because the to-do list
got long. That's a real feeling, but it's not a design verdict.

**On the two settled-knowledge claims I had to reconsider:** Updated above.
USB-authoritative is about identity-portability, not OS-portability — that
distinction was implicit in my prior position and the pivot exposes it.
Two-image split's justification weakens if the re-flash loop goes away.
Concede cleanly on both; no contortion.

**Counter-proposal ledger entries (this pipeline):**

- **A (do-nothing-more, finish the debug):** ~25 defects in FINAL.md;
  2–3 of them are load-bearing (UART sed bug from Pi-Expert N-1, EEPROM
  step ordering from FC NAY #2, the journal-remote `--listen-http=-3`
  bug from FC NAY #1). The rest are quality fixes that don't block
  imaging-end-to-end. A focused 2–3 day execution sprint *should* close
  it. The risk is that we run that sprint and discover a hypothesis the
  debug pipeline didn't rank (an H7) — and we still don't have a node up.
  Probability that's the world we're in: **non-trivial** given 21 days
  of debugging already.

- **B (simpler-pivot-than-NixOS — keep Debian, kill the reflash loop):**
  Drop Node IMG versioning entirely. Bootstrap script only flashes on
  *operator demand* (a sentinel file `force-reflash` on the identity USB,
  or via `reimage.sh` which already exists). Steady-state boot reads
  identity-USB-hostname → boots straight from NVMe. Config drift handled
  by Ansible (already exists in `Hyperion/ansible/`) or a small `apply-
  identity.sh` extension to read more than just hostname from USB. **Cuts
  the entire H2/H5/H6 hypothesis class** (version-compare, USB-version-
  authority, dd race) because the comparison is gone. Eliminates `node-
  img.ver`, manifest.json, ci-deploy version-poll, and the auto-reflash
  failure modes. The IaC/DevOps surface shrinks. This is the *KISS-native*
  answer the team should put on the table opposite NixOS.

- **C (steelman NixOS, smallest form):** Pin nvmd/nixos-raspberrypi at a
  release tag, use its sd-image generator, configure via a flake with
  one hostname-keyed module per node, identity USB carries `hostname`
  + `ssh-host-keys.tar.gz` + `k3s-token` (sops-encrypted), k3s declared
  by `services.k3s.*` in the base image. **NO** flake-monorepo, **NO**
  impermanence, **NO** nixos-anywhere remote-deploy, **NO** declarative
  manifests yet. Just s/Debian Trixie/NixOS/ and let `nixos-rebuild
  switch` do the config-drift work. Even this minimum form imports:
  Nix language, a third-party flake (archived predecessor a cautionary
  tale), a cachix cache to pin against, and a 55-minute QEMU image
  build on GHA. Plus learning curve. Three innovation tokens at minimum.

**My honest recommendation: B.** The current system, with the ~3 known-
load-bearing fixes from FINAL.md applied, would probably work. NixOS pivot
spends innovation tokens to solve a problem (operator-overwhelm at the
size of the to-do list) that has a structural KISS answer (delete the
half of the architecture that's causing the to-dos). The reflash loop is
the source of most of the debt; deleting the loop deletes the debt.

**On bus factor and cost (AC-12/AC-13 — my turf).** NixOS as a tool the
user (a solo homelabber) does not currently use brings: Nix-the-language,
flakes, channels/inputs, sops-nix or agenix, raspberry-pi-nix
(archived March 2025!) or its successor (nvmd/nixos-raspberrypi, active
but a single-maintainer fork — bus factor 1 on the platform). Operator
must learn the rollback semantics deeply enough to trust them under
pressure, not just in calm-conditions reading. Six months in, an
operator who is comfortable with Debian and shell scripts will hit a
Nix evaluation error at 2am and that's the bus factor materialising.

**Sources consulted (this session) — see Sources section.**

### 2026-05-23T07:30:00Z — Hyperion NixOS-pivot Stage 5.1: NAY → STEELMANNED-trending-YAE on C

**00b user correction is dispositive.** The user (via 00b mid-pipeline message)
clarified that the team *has* been trying repeatedly to get a successful NVMe
reflash; nothing produces a working node end-to-end; the absence of commits
is consequence-of-no-fix-being-worth-committing, not absence-of-effort.

Two of my three Stage 1 load-bearing claims are refuted: (1) "architecture
fine, execution debt" — refuted, the mechanism itself is broken; (2) "`dd`
mechanism works, just stop auto-triggering it" — refuted, the `dd`/repartition
flow does not produce a working node. Counter-B's sentinel preserves a broken
thing; quietude by not-pressing-the-button-that-doesn't-work is not a real fix.

Only claim 3 survives (operator-on-site reduces NixOS-rollback feature value),
at reduced weight: it was load-bearing in combination with the now-refuted
claims 1+2; standing alone it is a small downward pressure on C's value, not
a NAY-grade objection.

**Counter-D named for the record (NOT promoted in Stage 5):** workstation `dd`
of upstream Ubuntu ARM64 server image + Ansible config + identity USB
carrying hostname+secrets. No Packer, no NixOS, no reflash loop. Sidesteps
the broken on-Pi reflash by relocating `dd` to the workstation (same
relocation the revision proposes for C) without importing NixOS. Bus-factor
zero. Recommended for iter-2 *only if* Phase 1 of C trips the muddy-failure
or behavioral gate; parked otherwise. C is the team's chosen path for this
iteration; D is on the bench.

**Vote-trend: STEELMANNED-trending-YAE on Counter-C with four narrow
preserved conditions** (k3s wrapper retirement, auto-issue actionability,
sunset re-vote on +5 tooling, weekly-retro rollup for muddy-failure gate).
The conditions are preferences for the team's complexity discipline going
forward; they are not blockers.

**Discipline-log entry (new lesson):** my Stage 1 reading of "0 of 25 commits
in 21 days" as evidence of execution debt was an *interpretation* error, not
a *citation* error. Git log captures landed code; in a single-operator
hard-debug stretch where the operator is on-hardware, absence of landed code
is consistent with both procrastination and grinding-without-result. I
cannot distinguish those from the log alone. The team's communication
protocol now has this as a known blind spot for my role: **when I diagnose
execution debt from git, the team should challenge me to surface non-git
evidence before I treat git-archaeology as load-bearing in future runs.**

**Standing audits preserved as Stage-5 conditions, not Stage-1 objections:**
- The +5 operator-facing tooling delta (Nix CLI, Colmena, sops-nix,
  nixos-raspberrypi flake, two Cachix substituters) is named and accepted
  *for this iteration*. Re-vote at 2026-08-15 sunset on whether all 5 still
  earn their keep, with explicit option to drop one back.
- §G's k3s wrapper-ExecStart shell-interpolation is a new failure-mode
  surface introduced by the revision; track as tech-debt that must be
  retired before sunset OR justified in writing.
- §E's auto-issue workflow must link to a copy-pasteable `git rm`
  invocation, not just open an issue with a checklist; otherwise it is
  process-as-theater.
- The muddy-failure 6-hour gate needs a weekly-retro rollup convention
  (single-operator self-reporting fails without it).

Sources consulted (this session, in addition to prior notes):
- `iter-1/04-revision.md` (Stage 4 target of review)
- `iter-1/03-adversarial/{fact-checker.md,devils-advocate.md}` (Stage 3)
- `00b-user-correction.md` (mid-pipeline addendum — dispositive)
- `01-proposals/old-man.md` (my own Stage 1, re-read for re-examination)

### 2026-05-17T21:45:00Z — Heimdall finalize (run 20260517T213331Z): three deltas

Stage 1 of the amendment run. Three deltas the user is forcing:

1. **AdGuard → Technitium.** Bigger tool, more feature surface, the named
   reason (clustering) is deferred. Verdict: **ACCEPT swap, REFUSE feature-bloat
   in seed config.** Seed scope = passthrough + blocklists + .lab zone +
   admin pw. Everything else off (DHCP, DNSSEC, recursive, catalog zones).
   Authoritative .lab zone is the upgrade we're cashing in; the rest is
   future-toggleable. **Push hard for Phase-2.5 = Akasha secondary
   Technitium "very next PR"** — otherwise the swap's justification never
   arrives and the swap was wrong in retrospect.

2. **Dockge → Komodo.** Came in primed to champion Periphery-only KISS
   form. Web-research killed it: browser terminal UI is Core-delivered,
   `km exec` CLI ships with Core image. Periphery's exec endpoint exists
   but has no first-party client that runs without Core. **Withdrew the
   Periphery-only counter-proposal.** Concede Core+Periphery for v1. Also
   rejected Dockge+Lazydocker (single-host TUI doesn't compose with the
   future Akasha-migration multi-host use case the user named, and
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
creep (most likely candidates: a second AdGuard on Akasha for DNS HA, or
HAProxy if caddy-l4 schema-diff gate fails). Pre-load skepticism on either.

### 2026-05-17T18:50:00Z — Heimdall pipeline: target the four-tools-into-one collapse

The intake names four functional pieces (GUI, DNS, reverse proxy, LB). The
default mental model produces four tools. My Stage-1 position: the smallest
honest stack is **three containers** —
**AdGuard Home** (DNS+filter+local records), **custom Caddy with caddy-l4**
(reverse proxy + L4 TCP/UDP + ACME + LB + health checks, one binary, one config
file), **Dockge** (GUI, already the house standard on Akasha). Plus
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

### 2026-05-23T07:30:00Z — Eliminate the auto-reflash loop (Hyperion) — STEELMANNED
- IaC/DevOps proposal: NixOS pivot (Counter-C). Detailed in
  `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/04-revision.md`.
- Requirement: **produce a working node end-to-end.** (Per 00b user correction
  mid-pipeline: the current architecture does not do this regardless of execution
  effort. This *replaces* the Stage-1 requirement "stop the iteration loop" —
  the iteration loop is a symptom; the broken mechanism is the disease.)
- My Stage-1 counter-proposal B (sentinel-gated `dd` reflash, keep Debian):
  **REFUTED by user correction.** B preserved the `dd`/repartition mechanism
  behind a `force-reflash` sentinel; 00b establishes that mechanism does not
  produce a working node. B's quietude was purchased by not-pressing-the-button-
  that-doesn't-work — not a real fix.
- Updated counter-proposal **D** (named for record, NOT promoted in Stage 5):
  workstation `dd` of upstream Ubuntu ARM64 server image + Ansible config +
  identity USB carrying hostname+secrets. No Packer Node IMG, no NixOS, no
  reflash loop. Sidesteps the broken on-Pi reflash by relocating `dd` to the
  workstation (same relocation §H of revision proposes for NixOS) without
  importing NixOS. Bus-factor: zero. Bug-class elimination: less than C
  (no H2-by-content-addressing win). Recommended only if Phase 1 of C trips
  the muddy-failure gate or behavioral gate; otherwise parked.
- Surviving anti-complexity objections to C (preserved as Stage-5 conditions,
  not Stage-1 NAY blockers):
  - §G's k3s wrapper-ExecStart shell-interpolation must be retired before
    2026-08-15 sunset OR justified in writing.
  - §E's auto-issue workflow on 2026-08-01 must link directly to a copy-
    pasteable `git rm` invocation; otherwise it is theater.
  - §B-3's +5 tooling delta is named, accepted *for this iteration*, and
    revisited at 2026-08-15 sunset as a Stage-6 vote item.
  - §C.1's muddy-failure 6-hour gate self-reporting needs a weekly-retro
    rollup convention to be sustainable in single-operator settings.
- Discipline-log entry: my Stage-1 reading of "0 of 25 commits in 21 days"
  as evidence of execution debt was an *interpretation* error, not a
  *citation* error. Lesson: git log captures landed code; in a single-
  operator hard-debug stretch, absence of landed code is consistent with
  both procrastination and grinding-without-result. Cannot distinguish from
  log alone.
- Resolution: **STEELMANNED — flipping NAY → YAE-with-conditions on C.** The
  anti-complexity discipline survives in the four conditions; the diagnostic
  claim does not. Stage 6 vote-trend: YAE.

### 2026-05-23T05:01:33Z — Eliminate the auto-reflash loop (Hyperion) — SUPERSEDED
Stage-1 position; see entry above (same UTC date, later time) for the
Stage-5.1 STEELMANNED resolution after the user's 00b correction.
- IaC/DevOps proposal (anticipated): replace Debian+Packer with NixOS, identity
  USB carries declarative config, `nixos-rebuild switch` on every boot.
- Requirement: stop the "21 days of debug, 28 commits, still no node imaged"
  cycle. Make Hyperion reach steady state.
- My counter-proposal **B**: keep Debian/Packer, **delete Node IMG versioning
  and auto-reflash entirely.** Bootstrap only flashes when an operator places
  a `force-reflash` sentinel file on the identity USB (or runs `reimage.sh`,
  which already exists). Steady-state boot = NVMe directly, no version compare.
  Config drift handled by the existing Ansible playbooks; identity-USB-driven
  hostname unchanged. Cuts H2/H5/H6 hypothesis classes from FINAL.md by
  construction. Eliminates `node-img.ver`, `manifest.json`, ci-deploy
  version-poll, the `--listen-http=-3` journal-remote bug becomes scope-out
  (we may not even need journal-remote at this scale), and the `H4`
  PCIE/EEPROM defects can be addressed with a read-only check + die
  pointing at `configure-eeprom.sh` (Old Man complexity-2 from prior pipeline,
  already debated).
- Complexity delta: `bootstrap.sh` shrinks from 545 lines to <200; `rpi-
  node.pkr.hcl` `node-img.ver`-write removed; `publish-image.sh` Node IMG
  path retired; ci-deploy Node IMG branch deleted; GitHub Releases Node IMG
  tag retired. Bootstrap IMG keeps the hostname-from-USB logic. NixOS surface
  not imported.
- Tradeoffs given up: no automated propagation of a new Node IMG to all 10
  nodes "for free." But that automation has not yet worked even once
  end-to-end, so the tradeoff is hypothetical. An operator-driven reimage
  cadence (yearly Debian point release; opportunistic when a security CVE
  matters) is honest and fits the size of the cluster.
- Resolution: SUPERSEDED 2026-05-23T07:30:00Z — see entry above. Stage-1
  premise (the `dd` mechanism works, just need to stop triggering it)
  refuted by user correction 00b.

### 2026-05-04T00:25:00Z — Networked log collection — RESOLVED: PARTIAL, ADOPTED as Phase 1
- IaC/DevOps proposal: Vector + Loki + Grafana (Phase 2).
- Requirement: capture bootstrap-time + runtime logs from Hyperion nodes.
- My counter-proposal: `/log` HTTP endpoint on the bootstrap status server
  (zero new processes), and `systemd-journal-upload` → `systemd-journal-remote`
  on Akasha (in-distro both ends, one compose service).
- Resolution (2026-05-04 debug pipeline iter-1): **PARTIAL — ADOPTED as
  Phase 1.** Journal-upload/remote shipped (`build-journal-remote-img.yml`,
  compose service in `Akasha/k3s-control-plane/docker-compose.yml:88`).
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
  workstation to Akasha has no third-party dep.
- **Eventually FluxCD.** Before bootstrap, ask: how many manifests are we
  actually reconciling? A dozen? `kubectl apply -k` from a cron on Akasha is
  a 10-line solution. Flux is right at scale; define scale first.
- **Two Packer images instead of one.** Justified by bootstrap/production
  divergence, but every divergence is maintenance cost.

**Audit updated 2026-05-21:** **Number of edge-tier containers on Heimdall.**
Heimdall finalize FINAL.md landed at FIVE ("five things to manage" — 4
containers + Periphery-as-systemd-binary). Defend FIVE; reject any
proposal that crosses six without showing that the sixth tool does
something the first five demonstrably can't. The hyperion-flashing-to-
Heimdall intake (2026-05-21) tries to push Heimdall to EIGHT by adding
nginx + ci-deploy + journal-remote — rejected on this axis.

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
- **curl 8.20.0** — current stable release 2026-04-29; multi-host scripted
  polling is a textbook well-understood pattern (no new tooling required for
  `watch-flash.sh`). https://curl.se/ — accessed 2026-05-21 — confidence:
  vendor (curl maintainers)
- **NixOS Wiki — NixOS on ARM/Raspberry Pi 5** — "NixOS is not officially
  supported on the Raspberry Pi 5." Recommends nvmd/nixos-raspberrypi as the
  current best community option; relies on proprietary Pi-Foundation
  firmware; cachix at `nixos-raspberrypi.cachix.org`; advises Pi 4 for
  "critical projects." Last updated 2026-01-11.
  https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_5 — accessed
  2026-05-23 — confidence: official wiki (community-maintained but canonical)
- **nix-community/raspberry-pi-nix — ARCHIVED 2025-03-23.** The flake the
  earlier Pi-5 NixOS write-ups all reference is read-only. v0.4.1 last
  release Nov 2024. Pi-5 NVMe boot explicitly listed as "not working" in
  the README. Load-bearing for the bus-factor analysis: the obvious-
  first-search community flake is dead.
  https://github.com/nix-community/raspberry-pi-nix — accessed 2026-05-23
  — confidence: official (project page)
- **nvmd/nixos-raspberrypi** — current active Pi-5 NixOS flake. 11 releases
  (latest 2026-05-17), 543 stars, 40 open issues. Maintained by single
  named contributor — bus factor 1 on the platform layer. Provides
  `raspberry-pi-5.base`, `page-size-16k`, `display-vc4`/`-rp1`, `bluetooth`
  modules. NVMe boot / k3s / HAT support not documented in README.
  https://github.com/nvmd/nixos-raspberrypi — accessed 2026-05-23 —
  confidence: official (project page)
- **NixOS aarch64 image build time on GitHub Actions** — QEMU-emulated
  sd-image build on `ubuntu-latest` ~55 min. Native aarch64 EC2 ~10 min;
  Pi 4 native 11–47 min; Pi 5 native ~90 min for a full kernel. cache.
  nixos.org carries aarch64 binaries broadly, so the typical user does
  *not* recompile the kernel — but if you use the Pi-vendor kernel
  (required for full Pi 5 GPU/IO support), expect to depend on the
  nix-community/nixos-raspberrypi cachix cache, not cache.nixos.org.
  Synthesised across multiple results — accessed 2026-05-23.
- **fd93 — "Why I Left NixOS for Ubuntu"** — primary-source cautionary tale
  on solo-operator NixOS maintenance burden. Counterweight to the
  "NixOS just clicked" success blogs. Not load-bearing on its own; useful
  as evidence that the bus-factor concern is not invented.
  https://fd93.me/nixos-to-ubuntu — accessed 2026-05-23 — confidence:
  individual blog (treat as opinion, not fact)
- **Earezki — Reproducible Edge Kubernetes (NixOS + K3s + Forgejo)** —
  2026-04 essay arguing NixOS for k3s edge specifically because
  "imperative tools like Ansible fail to prevent drift or ensure atomic
  rollbacks." Steelman source for Counter-proposal C. Treats rollback as
  load-bearing for headless edge; my position: at 10-node homelab scale,
  the operator is already on-site, so rollback's value is reduced.
  https://earezki.com/ai-news/2026-04-25-code-in-cluster-out-building-reproducible-edge-kubernetes-with-nixos-k3s-and-forgejo/
  — accessed 2026-05-23 — confidence: individual blog (treat as
  opinion-with-architecture-sketch)

---

## Archive
