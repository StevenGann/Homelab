---
agent: Devil's Advocate
specialization: Strategic and logical adversary — attacks design, assumptions, scope, reasoning
role: Adversarial — every other agent's positions are targets
last_compacted_utc: 2026-05-21T16:35:00Z
last_updated_utc:   2026-05-21T16:35:00Z
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
- **Monolith as single point of failure.** k3s server, image registry,
  ci-deploy, healthcheck all on one TrueNAS box. Is the reproducibility story
  itself reproducible?
- **Monolith as log-aggregator SPOF.** journal-remote (Phase 1) and Loki/Vector
  (Phase 2) both put receiver on Monolith. Logs are most needed when something
  is failing — and the most likely thing to fail is Monolith. Worth surfacing
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

## Active observations — dev-heimdall-tech-stack iter-1

Scenarios I ran while reviewing `02-combined-draft.md` on 2026-05-17:

- **caddy-l4 stability scenario.** Maintainer is Matt Holt (Caddy author). The
  "experimental" warning may be conservative-by-default rather than
  load-bearing. Survived attack: still a real signal because the README is the
  maintainer's chosen advertisement; a team optimizing for *stability*
  shouldn't override an author's own hedge unless the FC produces release-
  history evidence of stability.
- **FTP-in-2026 scenario.** No FTP-only dependency named by user. SFTP solves
  the same surface without PASV / stick-tables / conntrack helper / port-range
  forwarding. Recommendation: strike from v1 unless dependency named.
- **AdGuard SPOF scenario.** Run-the-room: phone wakes from sleep at 0300,
  AdGuard container OOM'd 4 hours ago, phone has no DNS cache, can't resolve
  *anything*. Operator SSH'ing back to Heimdall by hostname also fails. The
  "24h cache cushion" only applies to AdGuard's *own* cache for already-asked
  names — clients without their own resolver cache (most consumer devices)
  break immediately. Mitigation: DHCP secondary DNS = UCG or Monolith.
- **Operator-in-the-loop GitOps tax scenario.** Caddyfile changes every time a
  new service hostname is added. At "20 services churning monthly" the Dockge-
  click tax compounds. But: same flow on Monolith works fine at 5 services
  rarely changing. Threshold question. Survives attack at current churn level.
- **Backup-punt scenario.** Heimdall NVMe dies. caddy/data/ is gone. Operator
  rebuilds host per runbook. First boot, Caddy requests cert for
  service-a.example.com — request blocked by LE rate limit if the operator has
  more than 5 certs and the rebuild hits within 168 hours of last issuance.
  Documented LE Failed Authorization limit: 5/hour/account/hostname (Failed)
  and 50/week/registered-domain (Issued). Real risk for any non-trivial
  number of public hostnames.
- **Hostconf-files-as-shadow-Ansible scenario.** §4.2 has 12 steps each
  `sudo install -m 0644 /opt/Homelab/Heimdall/hostconf/X /etc/Y`. That's an
  Ansible task list spelled out as shell. The "no Ansible" win evaporates if
  the failure mode (operator-typos-one-path) is the same.

---

## Active observations — dev-heimdall-finalize iter-1

Scenarios I ran while reviewing `02-combined-draft.md` on 2026-05-17:

- **"Five-tool ceiling" rule audit.** Iter-1 had a "three-container budget"
  that broke 67% in one run (3 → 5). The new "defend five, reject sixth
  without demonstrable case" rule is the same shape, one tick higher. Every
  candidate sixth tool (backup daemon, metrics exporter, cert-watcher) will
  arrive with a real failure as its "demonstrable case." Rule is trivially
  overridable. Made into pattern #16 below (the recurring-ceiling-rule).
- **Soft-deferral hit rate.** Repo only has two prior pipeline runs on
  disk — empirical base too thin to score the 2-month Technitium-secondary
  deadline. But the parent run (3 days ago) had three of its unanimous
  decisions re-opened by user-surfacing new info. "Days, not months" is the
  observed re-open velocity. Recommendation: replace soft "the swap was a
  mistake" rhetoric with a binary action-tagged deadline (revert OR ship).
- **Komodo onboarding step scenario.** §3.3 Phase 2 step 4 prescribes 8
  discrete operator actions (browser nav + clipboard + ssh + sed + restart)
  yet calls itself "one-shot manual step." Proposal §Risks #2 admits it's
  not yet scripted; doesn't admit it could be scripted with a `curl + jq`
  wrapper. 9-months-later failure mode: UI changes between v2.2 and v2.x
  (active development) and runbook describes a screen that no longer exists.
- **`bootstrap-zones.sh` failure-mode audit.** Specification gaps:
  prune-vs-additive semantics, retry on 5xx, API-version coupling. The
  "binary config changes across versions" argument against committing
  `dns.config` is asymmetric — API also changes across versions. Either
  defend the asymmetry or rename to `seed-zones.sh` and own the additive-only
  contract.
- **Drift-detection alert-volume scenario.** Komodo `RESOURCE_POLL_INTERVAL=1-hr`
  at week-12 steady state: ~3 drift alerts/week (Dependabot, poll-caddy-l4,
  Caddyfile edits). Not alert fatigue strictly; alert background-noise.
  Operator's mental model: orange badge always there; ignore. Worse:
  Dependabot PRs cause false-positive drift between PR-open and merge.
- **NodePort fanout multi-edit operator scenario.** Adding a k8s service:
  3 coordinated edits (Service manifest, Caddyfile, allocation table) vs
  MetalLB's 1 (LoadBalancer Service). Couples to iter-1 §C5 churn-threshold
  decision: NodePort fanout *guarantees* an edit per service. The two
  decisions will collide as service count grows.
- **MetalLB-deletion-tripwire premortem.** Read `Hyperion/k8s/` directly:
  `apps/.gitkeep`, `flux-system/.gitkeep`, MetalLB manifests only. Zero
  `Service: type=LoadBalancer` exist. Deletion is a free move today.
  Steelmanned: the cross-host PR's pre-flight discipline is correct *as a
  discipline* but vacuous on current cluster state.
- **Mongo working-set drift scenario.** `wiredTigerCacheSizeGB=0.25` caps
  WT cache at 250 MB; "under 256 MB combined" applies to idle Komodo.
  At month 6: audit log 500–2000 entries, Stack history 50–100 versions,
  100-connection pool ≈ 100 MB process RSS not in WT cache. Heimdall has
  32 GB so not a blocker; but the runbook should set expectations.
- **`.lab` internal-CA + IoT trust scenario.** Steelmanned: printers /
  Smart TVs / Chromecasts / game consoles don't reach `.lab` HTTPS in
  normal use. Trust-burden falls on operator-controlled devices, not IoT.
  Residual risk: future cluster pods reaching `.lab` HTTPS will fail
  trust check until CA root is distributed into pod images. Add a section
  to `trust-store-distribution.md` for k8s-pod trust before someone wastes
  2 hours on `x509: certificate signed by unknown authority`.
- **Phase 2 acceptance honesty audit.** Phase 2 acceptance = containers
  healthy + Periphery onboarded + CA root fetchable + Technitium resolves.
  Phase 2 does NOT prove: any LAN client uses Heimdall, any service is
  routed, any `.lab` record resolves. "Project complete at end of Phase 2"
  framing (Old Man) is technically correct per user phasing but
  operationally misleading — three Phase-3-ish runbook files exist as
  *steady-state* docs. Honest gate: at least one Phase 3 deliverable
  shipped (e.g., `komodo.lab` resolves end-to-end).
- **Cross-host PR ordering scenario.** (a) cross-host first: cluster has
  no LB between MetalLB removal and Heimdall Phase 3. Today empty
  (Challenge 7) so blast radius zero, but conditional on Flux-bootstrap
  timing. (b) Heimdall Phase 1+2 first, cross-host second, Phase 3 third:
  Heimdall stands up next to cluster; both LBs coexist briefly; safest
  given empty cluster. (c) parallel: 3-day inconsistent-state window
  cost. (b) wins.
- **Convergence-audit on Periphery-as-systemd.** All three specialists
  cited the *same* root constraint (Docker daemon restart). 3-of-3
  consensus is single-constraint × three witnesses, not triple-independent.
  Honest framing: "one constraint, three confirmations, container mode
  is also upstream-supported." Decision survives; framing is overconfident.

Pattern added to settled patterns (below): #16 recurring-ceiling-rule.

---

## Active observations — dev-hyperion-flashing-to-heimdall iter-1

Scenarios I ran while reviewing `02-combined-draft.md` on 2026-05-21:

- **Unnamed-deadline scenario.** "Before Monolith retirement" is in the draft as a sequencing gate without a date. Two extremes break the plan:
  (a) hardware-forces-emergency-retirement next week → Phase A & B both critical-path, no parallelism; (b) deadline slips 3 months → Phase A completes, SSD-debug runs against Monolith for two months, Phase B perpetually deferred until forced.
  Mitigation: contingency table with named triggers in §3.12. Pattern: #14 threshold-trigger that names no threshold.
- **"Temporary" posture as verbal tic.** Iter-1 Heimdall-finalize Technitium-secondary "6-month" deadline already showing drift; "Heimdall hosts Hyperion stack temporarily" is the same shape. Need a binary observable to trigger re-migration off Heimdall. Pattern: #14.
- **Parallel-track operator-attention scenario.** One-person team. The "Phase A and B run in parallel" framing hides whether the SSD debug or the migration leads. No synchronization gate at §3.10 step 7 (canary reflash) — should pre-require `watch-flash.sh` working against current Monolith.
- **The cutover-gate that cannot trip (BLOCKER).** §3.10 step 11 gates Monolith retirement on all 10 Pis successfully flashing — but this run delivers diagnostic tooling, not the SSD fix. If canary fails, step 11 never triggers and "temporary parallel deploy" becomes permanent split-brain. The defined failure mode: the new context (Monolith retiring) drives an unplanned emergency cutover when the original migration plan stalled. Fix: decouple "migration cut" from "SSD bug fixed."
- **`:latest`-tag regression scenario.** Same risk class as iter-1 Heimdall-finalize `komodo:latest`, but now applied to images the team itself publishes (`homelab-ci-deploy`, `homelab-journal-remote`). Versioned tags are a bounded CI change. Pattern: "we know this risk; we've already conceded it once."
- **Two-daemons-one-container coupled failure.** IaC's gatewayd-baked-into-journal-remote-image uses `wait -n` supervision. Either daemon's exit takes the other down. Cleaner: two containers sharing the same image, gatewayd mounts read-only. No new image, no new CI workflow.
- **The "two-reboot success" assumption is operator-dependent.** `BOOT_ORDER=0xf641` means SD-still-present → boots SD on reboot. Whether there are 1 cycle or 2 cycles before NVMe boot depends entirely on WHEN the operator pulls the medium. Pi Expert's own §6 describes 3 cycles; the draft's §1 unanimous row says "TWO." Both are right depending on operator behavior — neither is canonical. Need to define the protocol (leave SD in until cycle 2 completes) or split truth-table rows.
- **Three-pane TUI worse than one for live view.** Bottom pane (gatewayd SSE) shows same data as middle pane (`:8080/log`) at different latency. Operator reconciles two views of same thing. Gatewayd UI is the right post-mortem tool, not live.
- **Convergence-audit on 8 unanimous decisions.** Three of eight (rows 4 backup, 6 scope-creep, 7 success-signature) had shared-blind-spot patterns where the framing collapsed underlying disagreement or skipped failure modes. Rows 2, 3, 5, 8 clean. Pattern #14 applies to row 6 and 7.
- **Cross-host PR silence.** Both this run and the pending Heimdall-finalize cross-host PR modify `Monolith/k3s-control-plane/docker-compose.yml`. Draft says nothing about ordering. Merge-conflict surface unaddressed.

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

Prior pipeline-run summaries (dbg-nvme-not-flashing iter-1) are retained in
git history of this file; promoted patterns are now in §"Settled patterns"
above. Detailed ledger lives at
`docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/03-adversarial/devils-advocate.md`.
