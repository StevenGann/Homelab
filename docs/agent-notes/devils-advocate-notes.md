---
agent: Devil's Advocate
specialization: Strategic and logical adversary — attacks design, assumptions, scope, reasoning
role: Adversarial — every other agent's positions are targets
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-04T00:35:00Z
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

## Challenge ledger

Format per entry:

```
### YYYY-MM-DDTHH:MM:SSZ — <short position summary>
- Position: <verbatim or close paraphrase, with the source agent + file:line>
- Challenge: <the specific weakness, alternative, or scenario>
- Strongest counter-argument I can imagine (steelman): <…>
- Resolution: WITHDRAWN | STEELMANNED | OUTSTANDING | CHANGED <how>
- Cost-of-being-wrong: low | medium | high | catastrophic
```

<!-- Append new challenges at the bottom. Compaction merges duplicates and
     retires resolved-and-no-longer-relevant entries. -->

### 2026-05-04T00:35:00Z — pipeline-run dbg-nvme-not-flashing iter-1, attacks on `02-combined-draft.md`

Twelve challenges raised against the orchestrator's combined draft. Full
ledger lives in
`docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/03-adversarial/devils-advocate.md`.
Summary of resolutions and patterns worth carrying forward:

- **C-1 — observability-is-the-bug reframe.** STEELMANNED-with-edit. The
  Old Man's "the script is loud internally; the diagnostic surface is the
  fix" framing won. But: when the orchestrator says "the user is
  misreading the signal," that's a smell — the next time it appears, push
  back harder before accepting it.
- **C-2 — universal-first-step assumes operator capability.** PARTIAL.
  Pattern: any "step 1" that depends on operator skill / hardware /
  network position needs an explicit fallback chain, not just a
  decision-tree leaf labeled "escalate."
- **C-3 — H1 ranking attacks (too generous OR too lenient).** WITHDRAWN.
  The ranking didn't matter because the experiment splits the
  hypotheses regardless. Lesson: don't waste cycles attacking probability
  rankings when the next step distinguishes them anyway.
- **C-4 — H1c sleeper.** STEELMANNED. Old Man's "no while-we're-here
  fixes" wins. Latent bugs go in a backlog, not in the current PR.
- **C-5 — minimum-viable-fix is anti-complexity bias talking too early.**
  PARTIAL. Pattern: "minimum viable" framings should be hypothesis-
  conditional, not advertised as universal byte-counts.
- **C-6 — Phase-1-only dodges the user's stated request.** PARTIAL.
  Pattern: when an orchestrator picks an adversary's pre-conceded
  fallback, that's path-of-least-resistance, not adversarial review.
  Force the tradeoff to be made visibly (Phase 1 vs. Phase 2 buys what?)
  rather than implicitly via "let's defer."
- **C-7 — UART recommendation requires hardware not in hand.** PARTIAL.
  Pattern: split "Packer-time enable" (free) from "operator-time use"
  (requires hardware). Don't conflate them.
- **C-8 — "escalate" with no referent.** OUTSTANDING. Pattern: "escalate"
  in a single-operator project is doc-as-deflection.
- **C-9 — H5-sub should be promoted to its own H-number (proposed: H7).**
  PARTIAL. Pattern: when a "sub-finding" is structurally a different
  class of bug (build-time vs. runtime, IMG vs. script), promote it.
  Embedding it under the wrong parent hypothesis hides the diagnostic.
- **C-10 — single-cause assumption.** PARTIAL. Pattern: never-worked
  systems are usually multi-cause. Plans should expect to re-enter the
  pipeline after each individual fix.
- **C-11 — test-node selection ignores 4GB-vs-8GB hardware split.**
  PARTIAL. Per `MEMORY.md`, two Hyperion nodes are 4GB. Pi expert flagged
  this for runtime shippers. Worth carrying as a future trap whenever
  "pick a test node" appears.
- **C-12 — "fix bootstrap" is the wrong primary framing if the answer is
  operator-side.** CHANGED. Pattern: code-vs-docs framing matters because
  it affects what the team builds. When the modal fix is documentation,
  call docs the primary deliverable.

**New standing-challenge candidate (added to standing list):**
Monolith-as-aggregator is a SPOF for log collection during the moment
debugging is most needed (when something is failing). Both Phase 1
(journal-remote) and Phase 2 (Loki/Grafana) inherit this. Worth
revisiting if/when Monolith ever needs HA.

**Compaction note:** Ledger now has 12 new entries. Compaction window
opens 2026-05-05T00:35Z. Until then, append-only.

---

## Standing challenges to keep alive

Positions worth re-examining periodically because the answer can shift as the
project evolves.

- **"GitOps reconciles the cluster."** The repo is set up for it but FluxCD
  isn't bootstrapped (per `docs/todo.md` Step 10). Until it is, any plan that
  assumes "just commit and Flux will pick it up" is fiction. Force this to be
  said out loud whenever k8s manifests are discussed.
- **"USB-authoritative imaging is correct."** Steelman: it survives a network
  outage and is simpler than alternatives. Counter: it puts the per-node
  identity on a piece of consumer flash that has a finite write count. What's
  the failure mode when a HYPERION-ID stick wears out mid-cluster? Is there
  monitoring for this?
- **"The two-image split is good because PXE/TFTP failed on Pi 5."** Past
  failure justifies past decisions. It does not perpetually justify the current
  design. If the upstream Pi 5 / RP1 issues are eventually fixed, is netboot
  worth revisiting? Don't let "we tried that" become permanent.
- **Greek-letter hostnames** (alpha…kappa) — cute but capped at 24 nodes if you
  insist on the alphabet. What happens at node 11? Does the convention break or
  just get awkward (`hyperion-lambda` is fine until you hit `hyperion-omicron`).
  Worth deciding *before* it bites.
- **Single VLAN for everything.** `192.168.10.0/24` carries cluster traffic,
  MetalLB, the image server, and presumably workstation access. Is there a
  scenario where you'd want to isolate workload pods from the management plane?
- **Monolith as single point of failure.** k3s server, image registry,
  ci-deploy, and healthcheck all live on one TrueNAS box. The repo's whole
  reproducibility story rests on this one host being reproducible. Is it?
- **Monolith as the log-aggregator SPOF.** Both proposed log-collection
  designs (`systemd-journal-remote` Phase 1, Loki/Vector Phase 2) put the
  receiver on Monolith. Logs are most needed when something is failing —
  and the most likely thing to be failing during a hard outage is also
  Monolith (since it hosts everything). Pi-side disk buffers (Vector)
  partially mitigate; plain journal-upload does not. Worth surfacing as
  a known-acceptable tradeoff each time log collection is discussed,
  and revisited when/if Monolith gains an HA story. Added 2026-05-04
  during dbg-nvme-not-flashing iter-1.

---

## Common attack vectors

Patterns I look for when reviewing a position. Compaction promotes successful
attack patterns into this list.

1. **The "we already do X" justification.** Past adoption is not present
   correctness. Re-derive the choice from current constraints.
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

---

## Sources (frameworks I lean on)

- **Premortem analysis (Gary Klein, HBR)** — imagine the project failed; work
  backward from what killed it.
  https://hbr.org/2007/09/performing-a-project-premortem — accessed 2026-05-03 —
  confidence: community (canon)
- **Steelmanning** — the obligation to argue against the strongest version of
  the position, not the weakest. Concept attribution: Chana Messinger / various.
- **A Philosophy of Software Design (Ousterhout)** — "complexity is incremental"
  and "deep modules" inform many of my challenges. Book.
- **Choose Boring Technology (McKinley)** — the innovation-token framing is a
  useful weapon against shiny-object proposals.
  https://boringtechnology.club — accessed 2026-05-03 — confidence: community

---

## Archive

Resolved challenges (WITHDRAWN, STEELMANNED, or made moot by repo changes) kept
for historical context.
