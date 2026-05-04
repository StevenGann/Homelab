# PIPELINES.md

Two orchestration pipelines for running the agent team defined in [`TEAM.md`](TEAM.md):

- **DEVELOPMENT** — user provides requirements; team produces a plan to meet them.
- **DEBUGGING** — user provides a problem description; team hypothesizes causes, plans experiments to narrow hypotheses, and produces an implementation plan for the fix.

Both pipelines share the same iterative-revision-and-vote loop. They differ only in the **intake** and the shape of what the specialists produce in the first stage.

The orchestrator (the main Claude session you are talking to) drives the pipeline. Specialists, adversaries, and voters are invoked as `Agent` calls — independent specialists in parallel, adversaries in parallel, voters in parallel.

---

## Roles in the pipeline

From [`TEAM.md`](TEAM.md), six agents participate:

- **Specialists** (4): Linux Expert, Raspberry Pi Expert, Old Man, IaC/DevOps Expert
- **Adversaries** (2): Fact Checker, Devil's Advocate

The Old Man is a specialist for pipeline purposes (he produces independent research and reviews revisions like the others), and his standing-adversary stance toward the IaC/DevOps Expert simply means his proposals and reviews will lean anti-complexity — that's expected, not special-cased.

---

## Artifact storage

Each pipeline run gets its own folder for traceability:

```
docs/pipeline-runs/<UTC>-<dev|dbg>-<slug>/
├── 00-intake.md                     # User's requirements or problem statement
├── 01-proposals/                    # Stage 1 — independent specialist work
│   ├── linux-expert.md
│   ├── raspberry-pi-expert.md
│   ├── old-man.md
│   └── iac-devops-expert.md
├── 02-combined-draft.md             # Stage 2 — orchestrator's synthesis
├── iter-1/
│   ├── 03-adversarial/
│   │   ├── fact-checker.md          # Stage 3 — adversarial review
│   │   └── devils-advocate.md
│   ├── 04-revision.md               # Stage 4 — revised draft
│   ├── 05-review/                   # Stage 5 — specialist re-review
│   │   ├── linux-expert.md
│   │   ├── raspberry-pi-expert.md
│   │   ├── old-man.md
│   │   └── iac-devops-expert.md
│   └── 06-vote.md                   # Stage 6 — tally + rationales
├── iter-2/                          # Only created if iter-1 had ≥2 NAYs
│   └── ... same shape ...
└── FINAL.md                         # Pointer to the approved revision (copy of revision)
```

Slug is a short kebab-case hint (e.g. `add-flux-bootstrap`, `nodes-not-rejoining`). UTC is `YYYYMMDDTHHMMSSZ`.

---

## Shared stage machinery

### Stage 0 — Intake

The orchestrator captures the user's input verbatim into `00-intake.md`, then adds:

- **Pipeline:** `DEVELOPMENT` or `DEBUGGING`
- **Slug:** the chosen folder slug
- **Acceptance criteria** (DEVELOPMENT) or **definition of "fixed"** (DEBUGGING) — written by the orchestrator and confirmed implicitly by proceeding. If unclear, ask the user before continuing.

### Stage 1 — Independent specialist research (parallel)

Four `Agent` calls in a single message — one per specialist. Each gets:

- The full `00-intake.md`
- A pointer to its own notes file (`docs/agent-notes/<agent>-notes.md`) with instructions to consult and update it under the existing 24h compaction protocol
- The pipeline-specific output template (see DEVELOPMENT and DEBUGGING sections below)
- An explicit instruction: **do not read other specialists' proposals.** Independence is the point of this stage.

Output: `01-proposals/<agent-slug>.md`.

The Fact Checker and Devil's Advocate **do not** participate in Stage 1. They have nothing to attack yet.

### Stage 2 — Distill into combined draft

Orchestrator reads all four specialist proposals and produces `02-combined-draft.md`. This is **synthesis, not concatenation**:

- Identify points of agreement → state once.
- Identify disagreements → name the agents who disagree, summarize each position, recommend a default resolution with reasoning.
- Identify gaps where no specialist addressed a question raised by the intake → flag explicitly.
- Preserve attribution where it matters ("the Old Man's counter-proposal is …").
- For DEBUGGING: produce a single ranked hypothesis list, a single experiment plan, and a single contingent fix plan.
- For DEVELOPMENT: produce a single proposed approach with alternatives explicitly enumerated and rejected-with-rationale.

### Iteration loop

The loop runs as iterations `iter-1`, `iter-2`, … until the vote passes. Each iteration is:

#### Stage 3.n — Adversarial review (parallel)

Two `Agent` calls in a single message — Fact Checker and Devil's Advocate. Each gets:

- The current artifact under review:
  - `iter-1` reviews `02-combined-draft.md`
  - `iter-n` (n>1) reviews `iter-(n-1)/04-revision.md` plus the `06-vote.md` NAY objections
- Pointer to its own notes file with the standing 24h compaction protocol
- Instruction to use its existing ledger format (verdicts for FC; challenges for DA)

Output: `iter-n/03-adversarial/{fact-checker,devils-advocate}.md`.

Each adversary also appends new entries to its own notes file as part of normal operation.

#### Stage 4.n — Distill into revision

Orchestrator merges:

- The current draft (combined draft for iter-1; previous revision for iter-n>1)
- FC verdicts (CONFIRMED items survive unchanged; REFUTED items are corrected or dropped; UNVERIFIED items are flagged inline)
- DA challenges (each addressed: accepted-and-changed | rejected-with-rationale | partial-with-rationale)
- (iter-n>1) NAY objections from the previous vote — each addressed by the same accepted/rejected/partial rubric

Output: `iter-n/04-revision.md`. Every adversarial finding and every NAY objection from the previous iteration must be **named and resolved** in the revision — silent dropping is not allowed.

#### Stage 5.n — Specialist re-review (parallel)

Four `Agent` calls in a single message — the same four specialists from Stage 1. Each gets:

- `iter-n/04-revision.md`
- The two adversarial files from Stage 3.n
- Their own Stage 1 proposal (so they can see how it was incorporated or rejected)
- Instruction to focus on **new** issues introduced by the revision, not to re-litigate Stage 1

Output: `iter-n/05-review/<agent-slug>.md` with comments only — no vote yet.

#### Stage 6.n — Vote (parallel)

Six `Agent` calls in a single message — all four specialists plus both adversaries. Each gets:

- `iter-n/04-revision.md`
- All Stage 5.n review files
- Their own Stage 5.n review (or, for FC/DA, their Stage 3.n review)

Each agent returns a single ballot:

```
VOTE: YAE | NAY
RATIONALE: <one paragraph>
(NAY only) WHAT WOULD CHANGE MY VOTE: <concrete, addressable list>
```

The "what would change my vote" requirement on NAY ballots is non-negotiable — without it, the next iteration has no specific target. A NAY that doesn't include addressable conditions is treated as an abstention (counts as neither YAE nor NAY) and the agent is asked to re-vote.

#### Tally and decision

Orchestrator records all six ballots in `iter-n/06-vote.md` with the totals.

| NAY count | Outcome |
|-----------|---------|
| 0 or 1 | **PASS.** Promote `iter-n/04-revision.md` to `FINAL.md`. Pipeline ends. |
| ≥2 | **REVISE.** Open `iter-(n+1)/`. Carry the NAY ballots' "what would change my vote" lists forward as objections. Loop to Stage 3.(n+1). |

A single NAY does not block: the lone dissenter's objection is recorded in `FINAL.md` as a known concern. (This prevents one immovable agent from deadlocking the pipeline indefinitely.)

There is no maximum iteration cap by default. If a run exceeds 4 iterations, the orchestrator should pause and surface the situation to the user — that's a sign the requirement or problem statement itself needs revisiting, not more rounds.

---

## DEVELOPMENT pipeline

### Intake shape

User provides **requirements**: what should the system do, what constraints apply, what does success look like. The orchestrator's `00-intake.md` adds explicit **acceptance criteria** — bullet-pointed, testable.

### Stage 1 specialist proposal template (DEVELOPMENT)

```markdown
# <Agent Name> — Proposal for <slug>

## Summary
One paragraph: what I propose to do.

## Approach
The concrete plan, in steps. Files to create/modify, commands to run, ordering.

## Why this approach
Reasoning grounded in my specialty.

## Alternatives considered (and rejected)
- **<Alternative 1>** — rejected because <reason>.
- **<Alternative 2>** — rejected because <reason>.

## Risks and unknowns
What could go wrong; what I'm uncertain about.

## Effort estimate
S / M / L, with rough breakdown.

## Sources consulted
Citations from my notes file's Sources section, plus anything new I fetched.
```

### Stage 2 combined-draft additions (DEVELOPMENT)

Beyond the shared synthesis rules:

- **Acceptance-criteria coverage matrix** — every criterion from `00-intake.md` mapped to which part of the proposal addresses it. Gaps are explicit.
- **Named alternatives** — at least one specialist's rejected alternative must appear and be re-rejected with combined reasoning. (Forces alternatives to be visible.)

---

## DEBUGGING pipeline

### Intake shape

User provides a **problem description**: what's broken, observed symptoms, what was expected, when it started, what's been tried. The orchestrator's `00-intake.md` adds:

- **Definition of "fixed"** — the observable signal that the bug is resolved.
- **Known-good baseline** — when, if ever, was this last working.
- **Reproduction steps** — if the user provided them; if not, flag this as a gap to address in Stage 1.

### Stage 1 specialist proposal template (DEBUGGING)

```markdown
# <Agent Name> — Hypotheses for <slug>

## Top hypotheses (ranked)
1. **<Hypothesis>** — likelihood: H/M/L. Reasoning: <why>. Evidence I'd expect to see if true: <…>.
2. **<Hypothesis>** — …
3. **<Hypothesis>** — …

## Experiments to narrow the hypothesis space
For each: what to run, what result distinguishes which hypothesis, expected duration, side effects.

- **Experiment A:** <command/check>. If <result>, hypothesis 1 is confirmed/refuted.
- **Experiment B:** …

## Contingent fix plan
A fix plan **for each top hypothesis** that, if confirmed, this fix would address it. (Don't commit to a single fix yet — the experiments haven't run.)

## What I'd want to verify before any fix is applied
Pre-flight checks, backup steps, rollback plan.

## Sources consulted
```

### Stage 2 combined-draft additions (DEBUGGING)

Beyond the shared synthesis rules:

- **Merged ranked hypothesis list** — combine the four specialists' hypotheses into one ranked list, noting which specialists raised each.
- **Recommended experiment sequence** — order experiments by information-gain-per-effort. The first experiment should be the one that splits the hypothesis space most evenly.
- **Decision tree** — "if Experiment A returns X, run Experiment B; otherwise apply Fix Plan 1." Make the branching explicit.
- **Minimum-viable-fix path** — the shortest sequence of experiments + fix that resolves the most likely hypothesis. The Old Man should be expected to push for this.

---

## Concrete invocation pattern (orchestrator-side)

When you (the orchestrator) run a pipeline, the structure of your work is:

1. **Stage 0**: Write `00-intake.md` directly (no agents).
2. **Stage 1**: Single message with **4 parallel `Agent` calls** to the specialist subagents. Each prompt includes the intake, the agent's notes-file path, the Stage 1 template for the chosen pipeline, and the no-peeking instruction.
3. **Stage 2**: Read all four proposals; write `02-combined-draft.md` directly (no agents).
4. **Loop iteration n** begins:
   - **Stage 3.n**: Single message with **2 parallel `Agent` calls** (FC, DA).
   - **Stage 4.n**: Read both adversarial files; write `04-revision.md` directly (no agents).
   - **Stage 5.n**: Single message with **4 parallel `Agent` calls** (specialists).
   - **Stage 6.n**: Single message with **6 parallel `Agent` calls** (all six). Tally; write `06-vote.md` directly.
5. Decide PASS or REVISE per the table above. If PASS, write `FINAL.md` (a copy of the approved revision plus a header citing the iteration count and any single-NAY known concern).

The number of agent invocations per full run is small and bounded: 4 + 2 + 4 + 6 = 16 per iteration, with most runs converging in 1–2 iterations. Always batch parallel calls into a single message.

---

## Summary diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ Stage 0: Intake (user → orchestrator)                           │
│   00-intake.md                                                   │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 1: Independent specialist research (parallel × 4)         │
│   Linux · Pi · Old Man · IaC/DevOps                              │
│   01-proposals/*.md                                              │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 2: Orchestrator distills → combined draft                 │
│   02-combined-draft.md                                           │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
        ╔══════════════════ LOOP (iter-n) ═══════════════════╗
        ║ Stage 3.n: Adversarial review (parallel × 2)        ║
        ║   FC · DA                                            ║
        ║   iter-n/03-adversarial/*.md                         ║
        ║                       │                              ║
        ║                       ▼                              ║
        ║ Stage 4.n: Orchestrator distills → revision         ║
        ║   iter-n/04-revision.md                              ║
        ║                       │                              ║
        ║                       ▼                              ║
        ║ Stage 5.n: Specialist re-review (parallel × 4)      ║
        ║   iter-n/05-review/*.md                              ║
        ║                       │                              ║
        ║                       ▼                              ║
        ║ Stage 6.n: Vote (parallel × 6)                       ║
        ║   iter-n/06-vote.md                                  ║
        ║                       │                              ║
        ║         ┌─────── NAY count? ───────┐                ║
        ║         ▼                          ▼                 ║
        ║      0 or 1                       ≥2                 ║
        ║         │                          │                 ║
        ║         ▼                  next iteration ──┐        ║
        ║      PASS                                    │        ║
        ╚══════════════════════════════════════════════╪═══════╝
                                                       │
                                                  loop back
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ FINAL.md (approved revision + iteration count + known concern)  │
└─────────────────────────────────────────────────────────────────┘
```
