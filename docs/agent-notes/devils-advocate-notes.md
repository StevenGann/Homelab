---
agent: Devil's Advocate
specialization: Strategic and logical adversary — attacks design, assumptions, scope, reasoning
role: Adversarial — every other agent's positions are targets
last_compacted_utc: 2026-06-01T00:00:00Z
last_updated_utc:   2026-06-01T00:00:00Z
---

# Devil's Advocate — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (consolidate challenges, retire ones whose subject is
> gone, drop noise), then update `last_compacted_utc`. See `TEAM.md` for the full
> protocol.

**Scope.** Attack the *reasoning*, not just the facts. Where the Fact Checker
asks "is this true?", I ask "is this the right thing to be doing, even if
true?" Concretely:

- The premise of a plan
- The assumed failure modes (and the unassumed ones)
- The chosen tradeoff vs. the alternatives that weren't named
- Reversibility — what does it cost to back out of this?
- Scope creep — is this fixing the actual problem, or an adjacent one?
- Hidden coupling — what new thing now depends on this?
- Survivorship bias in citing past success

**Adversarial contract** (per `TEAM.md`):

- Every challenge names the specific position, the counter-scenario or
  alternative, and what would change my verdict. "I disagree" is not a critique.
- I challenge the Fact Checker too — sometimes the verified claim is true *and*
  the wrong claim to be focused on.
- Concession is fine. When a position survives the strongest challenge I can
  mount, I record it as STEELMANNED — that's a stronger endorsement than no
  challenge at all.
- Critique positions, not agents.

---

## Settled patterns (promoted from prior runs)

Patterns that have survived multiple challenges and are worth reusing as
attack vectors without re-deriving them each time.

1. **"We already do X" is past-performance bias.** Past adoption is not present
   correctness. Re-derive the choice from current constraints. (From
   dbg-nvme-not-flashing iter-1.)
2. **The unnamed alternative.** A plan that doesn't enumerate its alternatives
   is hiding work, not avoiding it.
3. **The optimistic concurrency assumption.** "Two of these won't run at once"
   is almost always wrong eventually. Force the locking story.
4. **The implicit ordering.** "X happens before Y" needs a mechanism, not just
   a sequence on the page.
5. **The disposable abstraction.** "We'll redo this later" code outlives the
   author. Either commit to the abstraction or skip it.
6. **The happy-path doc.** A runbook that doesn't tell you what to do when the
   command fails is a sales brochure.
7. **The single-source-of-failure hidden as a feature.** "Centralized" and
   "single point of failure" are the same architecture from different angles.
8. **The hypothesis-conditional minimum-viable-fix.** "Minimum viable" framings
   should be hypothesis-conditional, not universal byte-counts. (From C-5
   dbg-nvme-not-flashing.)
9. **The build-time-vs-operator-time split.** Don't conflate "Packer enabled X"
   (free) with "operator can use X" (requires hardware/skill). Split them.
   (From C-7 dbg-nvme-not-flashing.)
10. **The "escalate" deflection.** In a single-operator project, "escalate" with
    no referent is doc-as-deflection. (From C-8 dbg-nvme-not-flashing.)
11. **The wrong-parent sub-hypothesis.** When a sub-finding is structurally a
    different class of bug, promote it to its own H-number. (From C-9.)
12. **The single-cause assumption on never-worked systems.** Multi-cause is the
    default. Plans should expect to re-enter the pipeline after each fix.
    (From C-10.)
13. **Code-vs-docs framing matters.** If the modal fix is docs, call docs the
    primary deliverable. (From C-12.)
14. **The threshold-trigger that names no threshold.** "If it grows past X we'll
    extract Y" is only honest if X is defined now. (Pattern emerging in
    dev-heimdall, §3 point C "no Ansible for v1" + §3 point H "rebuild when
    breakage matters.")
15. **The cost-free addition.** "Including X costs nothing" is almost never
    true: every dependency is attack surface, release-tracking burden, and a
    potential bug-trigger on paths the operator doesn't use. (Pattern emerging
    in dev-heimdall, §3 point H "bake caddy-dns/cloudflare in because free.")
16. **The recurring-ceiling rule.** "Defend N; reject N+1 without a
    demonstrable case" rules are trivially overridable because every N+1
    candidate arrives *with* a real failure as its case. Rule is load-bearing
    only if it names what evidence does NOT count (e.g., "operator-convenience
    does not qualify; only failure modes the current N cannot mitigate do").
    Otherwise it's a narrative device for narrating the next breach.
    (From dev-heimdall-finalize Challenge 1.)
17. **The renamed-not-eliminated bug class.** When a plan claims to eliminate
    a bug class via architectural change, check whether the bug class is
    actually structurally gone or just relocated to a different host /
    different code path / different layer. "Eliminated" only holds if the
    new architecture cannot express the bug at all. (From C-1, C-4
    dev-nixos-identity-usb iter-1.)
18. **Learning-curve hours vs operational-tax hours are different costs.**
    "20 hours of ramp-up" estimates fluency, not the recurring quarterly
    fight with the new tool's failure modes. Demand both numbers when a
    plan invokes a learning curve. (From C-5 dev-nixos-identity-usb iter-1.)
19. **The clean-failure gate without a muddy-failure rule.** A go/no-go
    gate that names only "fails twice" leaves the team rationalizing sunk
    cost on every intermittent or partial failure. Demand a metric +
    threshold + window for the muddy case. (From C-6 dev-nixos-identity-usb
    iter-1; generalizes #16 recurring-ceiling-rule to phase gates.)
20. **The sunset date without enforcement.** Naming a retirement date is
    necessary but not sufficient. Without an accountable person, a concrete
    trigger (calendar item, auto-issue, CI check), and explicit
    extend-vs-execute criteria, "sunset" is doc-as-deflection.
    (From C-8 dev-nixos-identity-usb iter-1; generalizes pattern #5
    disposable-abstraction.)
21. **The single-host pivot leaks to multi-host scope creep.** When a
    pipeline pivots one host to a new platform, the unanswered question
    "do the other hosts follow?" usually means "yes, eventually,
    unbudgeted." Force the answer up-front: dual-stack-forever or
    cluster-wide-pivot-on-success. (From C-7 dev-nixos-identity-usb iter-1.)
22. **The pivot-as-procrastination pattern.** When a team that hasn't been
    finishing its current backlog proposes a platform pivot, the freshness
    of the new platform can mask the underlying execution-debt issue.
    Demand a behavioral acceptance test (commit velocity, defect-close
    rate) as a phase exit criterion. (From C-11 dev-nixos-identity-usb iter-1.)

---

## Standing challenges to keep alive

Positions worth re-examining periodically because the answer can shift as the
project evolves.

- **"GitOps reconciles the cluster."** FluxCD isn't bootstrapped (per
  `docs/todo.md` Step 10). Any plan that assumes "just commit and Flux will
  pick it up" is fiction. Force this to be said out loud when k8s manifests
  are discussed.
- **"USB-authoritative imaging is correct."** Steelman: it survives a network
  outage and is simpler than alternatives. Counter: it puts per-node identity
  on consumer flash with finite write count. Failure mode when a HYPERION-ID
  stick wears out mid-cluster? Is there monitoring?
- **"The two-image split is good because PXE/TFTP failed on Pi 5."** Past
  failure justifies past decisions, not perpetually current ones. If upstream
  Pi 5 / RP1 issues are eventually fixed, is netboot worth revisiting?
- **Greek-letter hostnames** capped at 24 nodes. What happens at node 11+?
  Decide *before* it bites.
- **Single VLAN for everything.** `192.168.10.0/24` carries cluster traffic,
  MetalLB, image server, workstation. Scenario for isolating workload pods
  from the management plane?
- **Akasha as single point of failure.** k3s server, image registry,
  ci-deploy, healthcheck all on one TrueNAS box. Is the reproducibility story
  itself reproducible?
- **Akasha as log-aggregator SPOF.** journal-remote (Phase 1) and Loki/Vector
  (Phase 2) both put receiver on Akasha. Logs are most needed when something
  is failing — and the most likely thing to fail is Akasha. Worth surfacing
  each time log collection is discussed.
- **Heimdall as DNS SPOF.** Added 2026-05-17 during dev-heimdall iter-1.
  AdGuard down → LAN clients lose name resolution within their cache TTL,
  including operator's own ability to SSH back by hostname. Mitigation
  (secondary DNS in DHCP) is one-line; punting it is a load-bearing punt.
  Worth revisiting if/when Heimdall ever gains an HA story or a sibling box.
- **Caddy ACME store as cert-loss SPOF.** Added 2026-05-17 during
  dev-heimdall iter-1. Loss of `caddy/data/` → re-issue every LE cert at
  once → hit rate limits → effectively CA-banned for ~week. Backup target
  punted in draft. This is a load-bearing punt. Revisit if any LE-issued
  cert is added.
- **UCG as DHCP + L3 SPOF.** Added 2026-05-17. If UCG dies, LAN has no DHCP
  and no path to Heimdall for new clients — Heimdall's own SPOF status is
  smaller than UCG's. Worth re-examining whether obsessing over Heimdall HA
  while UCG is single-box is even rational.

---

## Active observations — dev-nixos-identity-usb iter-1 (2026-05-23)

Stage 3 review of `02-combined-draft.md` targeting the orchestrator's choice
to recommend PROCEED WITH THE PIVOT (Counter-C) over the Old Man's NAY
(Counter-B). Full ledger at
`docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/03-adversarial/devils-advocate.md`.
16 challenges issued: 1 CRITICAL, 6 HIGH, 6 MEDIUM, 3 LOW (revised tally per
ledger summary table including C-15 LOW).

**Top 3 most consequential (would flip orchestrator's recommendation if
unaddressed):**

- **C-6 muddy-failure exit rule (CRITICAL).** Phase 1 gate names "fails
  twice" but not "fails intermittently / partially / on day 5." Without a
  named metric + threshold + window for the muddy case, sunk-cost
  rationalization will keep the pivot alive even when it's failing —
  exactly the failure mode the Old Man's 24-of-25-defects-uncommitted
  evidence documents.
- **C-5 bus-factor as operational tax (HIGH).** AC-12's 20-40 hour ramp-up
  estimate is fluency cost, not the recurring quarterly fight (estimated
  6-12 hours per quarter) when Nix breaks in non-obvious ways at 2am.
- **C-11 pivot-as-procrastination (HIGH).** The combined draft's assertion
  that "architecture switch IS the escape from the quagmire" is not
  falsifiable. The team that hasn't been finishing its Debian backlog may
  not finish its NixOS backlog either; the pivot changes vocabulary, not
  execution.

**STEELMANNED (came in primed to attack, conceded):**

- Native ARM runners as load-bearing argument — IaC Expert's 5-25 min
  benchmark vs 50 min QEMU baseline checks out per actuated.com.
- `imports` is evaluation-time — Linux Expert's hard NAY on user's
  stated config-on-USB-imported-at-boot model is structurally correct;
  the hybrid (runtime EnvironmentFile + sops-nix from USB-staged age key)
  preserves user intent while honoring constraint.
- H2 (version-compare) genuinely structurally gone under NixOS;
  generations are store-path-keyed, not integer-keyed.
- Counter-B is preserved as a real fallback (Phase 0 items 1, 2, 3 are
  load-bearing under both paths; the bridge is concrete not rhetorical).

**Patterns promoted to settled patterns**: #17 renamed-not-eliminated,
#18 learning-curve-vs-operational-tax, #19 clean-failure-gate-without-muddy-rule,
#20 sunset-date-without-enforcement, #21 single-host-pivot-multi-host-creep,
#22 pivot-as-procrastination.

---

## Active observations — dev-hyperion-flashing-to-heimdall iter-1

Scenarios I ran while reviewing `02-combined-draft.md` on 2026-05-21:

- **Unnamed-deadline scenario.** "Before Akasha retirement" is in the draft as a sequencing gate without a date. Two extremes break the plan:
  (a) hardware-forces-emergency-retirement next week → Phase A & B both critical-path, no parallelism; (b) deadline slips 3 months → Phase A completes, SSD-debug runs against Akasha for two months, Phase B perpetually deferred until forced.
  Mitigation: contingency table with named triggers in §3.12. Pattern: #14 threshold-trigger that names no threshold.
- **"Temporary" posture as verbal tic.** Iter-1 Heimdall-finalize Technitium-secondary "6-month" deadline already showing drift; "Heimdall hosts Hyperion stack temporarily" is the same shape. Need a binary observable to trigger re-migration off Heimdall. Pattern: #14.
- **Parallel-track operator-attention scenario.** One-person team. The "Phase A and B run in parallel" framing hides whether the SSD debug or the migration leads. No synchronization gate at §3.10 step 7 (canary reflash) — should pre-require `watch-flash.sh` working against current Akasha.
- **The cutover-gate that cannot trip (BLOCKER).** §3.10 step 11 gates Akasha retirement on all 10 Pis successfully flashing — but this run delivers diagnostic tooling, not the SSD fix. If canary fails, step 11 never triggers and "temporary parallel deploy" becomes permanent split-brain. The defined failure mode: the new context (Akasha retiring) drives an unplanned emergency cutover when the original migration plan stalled. Fix: decouple "migration cut" from "SSD bug fixed."
- **`:latest`-tag regression scenario.** Same risk class as iter-1 Heimdall-finalize `komodo:latest`, but now applied to images the team itself publishes (`homelab-ci-deploy`, `homelab-journal-remote`). Versioned tags are a bounded CI change. Pattern: "we know this risk; we've already conceded it once."
- **Two-daemons-one-container coupled failure.** IaC's gatewayd-baked-into-journal-remote-image uses `wait -n` supervision. Either daemon's exit takes the other down. Cleaner: two containers sharing the same image, gatewayd mounts read-only. No new image, no new CI workflow.
- **The "two-reboot success" assumption is operator-dependent.** `BOOT_ORDER=0xf641` means SD-still-present → boots SD on reboot. Whether there are 1 cycle or 2 cycles before NVMe boot depends entirely on WHEN the operator pulls the medium. Pi Expert's own §6 describes 3 cycles; the draft's §1 unanimous row says "TWO." Both are right depending on operator behavior — neither is canonical. Need to define the protocol (leave SD in until cycle 2 completes) or split truth-table rows.
- **Three-pane TUI worse than one for live view.** Bottom pane (gatewayd SSE) shows same data as middle pane (`:8080/log`) at different latency. Operator reconciles two views of same thing. Gatewayd UI is the right post-mortem tool, not live.
- **Convergence-audit on 8 unanimous decisions.** Three of eight (rows 4 backup, 6 scope-creep, 7 success-signature) had shared-blind-spot patterns where the framing collapsed underlying disagreement or skipped failure modes. Rows 2, 3, 5, 8 clean. Pattern #14 applies to row 6 and 7.
- **Cross-host PR silence.** Both this run and the pending Heimdall-finalize cross-host PR modify `Akasha/k3s-control-plane/docker-compose.yml`. Draft says nothing about ordering. Merge-conflict surface unaddressed.

---

## Active observations — dev-arr-stack-on-hyperion (2026-06-01)

Stage-3 adversarial review of `arr-stack-plan-combined-draft.md`. New patterns:

23. **The parallel-taxonomy defect.** A draft that proposes a NEW label/scheme
    (`homelab/mem=8gb`) without reading the in-tree one (`hyperion.lab/memory-tier=`)
    creates two competing conventions. Worse here: in-tree only the 4 GB nodes are
    labeled+tainted PreferNoSchedule; 8 GB is the unlabeled default. A
    `nodeSelector: homelab/mem=8gb` matches ZERO nodes → every pod Pending. The
    "declare it in Nix not kubectl" advice was right; the label name was invented
    against an existing scheme nobody checked. Generalizes #1 (we-already-do-X) to
    its inverse: failing to find the existing X and reinventing it.
24. **The mis-scoped risk citation.** Citing a bug report (#2970: UID 5000 +
    SELinux-permissive on AlmaLinux) as a live risk for a config the bug does NOT
    implicate (UID 1000 = image's native `node` user) inflates a risk register
    with a non-applicable hazard. Verify the bug's *trigger conditions* match the
    plan's config before promoting to R-list.
25. **The "verified" that's half-true.** C5 said the "no-semver" concern was purely
    a GHCR package-page artifact. Reality: GitHub Releases IS semver (v3.2.0,
    2026-04-15, arm64 manifest confirmed by me) — BUT `ghcr tags/list` surfaces
    only up to v3.0.1; v3.2.0 pulls by reference yet is absent from the tag index.
    Both prior positions were partly right. "VERIFIED" should report the split,
    not pick a winner.

**Top consequential challenges this run (detail in final response):**
- C-A: §5 nodeSelector `homelab/mem=8gb` matches zero nodes (deploy-blocker;
  use existing `hyperion.lab/memory-tier`, rely on the existing 4gb taint).
- C-B: R1 nfs-utils is not "unverified," it is verifiably ABSENT from the entire
  nixos tree — a hard preflight that gates the WHOLE design, hidden in §9.
- C-C: single NFS export is a stack-wide SPOF; `hard` mount means Akasha reboot
  → every media pod blocks indefinitely (by design) — recovery story missing.
- C-D: "mirror hermes" is selective — hermes is `:latest`, per-app-namespace.
- C-E: Tdarr server-on-Pi while sole worker is Thoth — server adds a Pi NIC hop
  + an NFS-SPOF dependency for the DB; why not server on Thoth too.
- C-F: ~12-service scope vs lean core; the EXDEV canary + seed-script + grep-gate
  verification tax is the real cost, and it scales with service count.

---

## Sources

- **caddy-l4** project README: https://github.com/mholt/caddy-l4 — Matt Holt
  maintainer; "still in development" warning present 2026-05-17 (verified by
  Linux Expert in Stage 1).
- **Let's Encrypt rate limits**:
  https://letsencrypt.org/docs/rate-limits/ — 50 certs/week/registered-domain;
  5 Failed Authorizations/hour/account/hostname; 5
  duplicate-certificate/week. Accessed via prior Devil's Advocate notes;
  confidence: official. Relevant to backup-loss scenario.
- **Caddy on-demand TLS + ACME storage**:
  https://caddyserver.com/docs/automatic-https — `data/` directory holds
  account keys + issued certs. Accessed via Old Man citations 2026-05-17.
- **HAProxy 3.0 LTS lifecycle**: HAProxy.com release-management page —
  pending FC verification.
- **Premortem analysis (Gary Klein, HBR)**:
  https://hbr.org/2007/09/performing-a-project-premortem — used to drive
  the "phone-wakes-at-0300-with-no-DNS" scenario above.
- **Choose Boring Technology (McKinley)**: https://boringtechnology.club —
  used to attack the "cost-free addition" of caddy-dns/cloudflare into the
  baked image.

---

## Archive

Prior pipeline-run summaries are retained in git history of this file;
promoted patterns are now in §"Settled patterns" above. Detailed ledgers
live with their respective pipeline runs:

- `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/03-adversarial/devils-advocate.md`
- `docs/pipeline-runs/<dev-heimdall-tech-stack>/iter-1/03-adversarial/devils-advocate.md`
  (if landed) — observations compacted 2026-05-23 (patterns promoted, raw
  scenarios in git history of this file).
- `docs/pipeline-runs/<dev-heimdall-finalize>/iter-1/03-adversarial/devils-advocate.md`
  (if landed) — observations compacted 2026-05-23 (patterns promoted, raw
  scenarios in git history of this file).
- `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/03-adversarial/devils-advocate.md`
