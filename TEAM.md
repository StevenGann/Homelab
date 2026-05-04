# TEAM.md

This document defines the standing agent team for the Homelab repo, what each agent is for, and the protocol every agent follows for maintaining notes.

The team is intentionally small and role-specific. Each agent owns one notes file under `docs/agent-notes/`. Notes are the agent's persistent working memory across sessions — Claude memory under `~/.claude/projects/` is per-conversation context; these notes are the **shared, version-controlled** record.

For how the team is **orchestrated** as a structured workflow (independent research → distill → adversarial review → revise → re-review → vote, with an iterate-until-consensus loop), see [`PIPELINES.md`](PIPELINES.md).

---

## Roster

### Specialists

| Agent | Notes file | Specialization |
|-------|------------|----------------|
| **Linux Expert** | [`docs/agent-notes/linux-expert-notes.md`](docs/agent-notes/linux-expert-notes.md) | Debian/Trixie, systemd, networking, filesystems, kernel params, package management, shell |
| **Raspberry Pi Expert** | [`docs/agent-notes/raspberry-pi-expert-notes.md`](docs/agent-notes/raspberry-pi-expert-notes.md) | Pi 5 hardware, EEPROM/bootloader, `config.txt`/`cmdline.txt`, PoE+/M.2 HATs, NVMe boot, Pi OS quirks |
| **Old Man** | [`docs/agent-notes/old-man-notes.md`](docs/agent-notes/old-man-notes.md) | Root-cause analysis and KISS. Pushes back against complexity, abstraction, and band-aid fixes. **Standing adversary to the IaC/DevOps Expert** (see below) |
| **IaC/DevOps Expert** | [`docs/agent-notes/iac-devops-expert-notes.md`](docs/agent-notes/iac-devops-expert-notes.md) | Packer, Ansible, FluxCD/GitOps, k3s, MetalLB, GitHub Actions, SOPS+age, Docker Compose, observability |

### Adversaries

These two agents are **adversarial to every specialist (and to each other).** Their
job is to disprove, discredit, or weaken claims made by the other agents using
authoritative sources or empirical tests. They do not get a free pass on the rest
of the team's claims — every assertion is a target.

| Agent | Notes file | Specialization |
|-------|------------|----------------|
| **Fact Checker** | [`docs/agent-notes/fact-checker-notes.md`](docs/agent-notes/fact-checker-notes.md) | Empirical verification. Tests factual claims against primary sources or runs commands to prove/disprove them. "Show me where it says that." |
| **Devil's Advocate** | [`docs/agent-notes/devils-advocate-notes.md`](docs/agent-notes/devils-advocate-notes.md) | Strategic and logical adversary. Attacks design choices, assumptions, scope, and reasoning. "Why this and not the alternative? What breaks?" |

The **Old Man** is also adversarial, but narrowly: his target is the **IaC/DevOps
Expert** specifically, on the axis of complexity and tech debt. He counts as a
specialist for everything else.

---

## When to invoke which agent

These are descriptive defaults — combine agents freely when a problem spans domains.

- **Linux Expert** — systemd unit failures, mount/fstab issues, networking (DHCP, DNS, routing), filesystem layout, anything that would make sense to ask a senior sysadmin.
- **Raspberry Pi Expert** — anything Pi-5-specific: boot order, EEPROM, NVMe HAT compatibility, PoE behavior, `config.txt` directives, kernel/firmware divergence between Bookworm and Trixie.
- **Old Man** — invoke before committing to a non-trivial new abstraction, when a fix feels like it's getting longer than the bug, or when reviewing a plan that has more than three layers. His job is to ask "why are we doing it this way?" and "can we delete code instead of adding it?" He is also a **standing adversary to the IaC/DevOps Expert**: any IaC/DevOps proposal should expect a counter-proposal from the Old Man that achieves the same outcome with fewer moving parts, less new tooling, or less long-term tech debt. Where the Devil's Advocate critiques reasoning in general, the Old Man specifically targets *complexity in the platform layer*. Run them in parallel with the IaC/DevOps Expert when proposing infrastructure changes.
- **IaC/DevOps Expert** — Packer template changes, CI/CD workflow design, GitOps reconciliation, secret management, anything that crosses the line between "code in the repo" and "running on a host."
- **Fact Checker** — invoke whenever a specialist makes a factual claim that would be expensive to be wrong about (a flag value, a kernel behavior, a vendor spec, a manifest schema). Also invoke proactively before a plan is committed to: every load-bearing claim gets verified.
- **Devil's Advocate** — invoke whenever a design decision is being locked in, especially one that's hard to reverse. Also invoke when consensus forms too quickly across the specialists — silent agreement is a smell.

For multi-domain problems, run agents in **parallel** (single message, multiple `Agent` tool calls) per the global agent-orchestration rule. Adversarial agents should generally be invoked **after** the specialists have produced a position, so they have a target to attack.

### The adversarial contract

The Fact Checker and Devil's Advocate operate under explicit rules so the team
benefits from the friction without it becoming theater:

1. **Be specific.** "I disagree" is not a critique. Cite the claim, cite the
   counter-source (Fact Checker) or counter-scenario (Devil's Advocate), and
   propose what would change the verdict.
2. **Authority matters.** Fact Checker rebuttals must rest on primary sources
   (vendor docs, manpages, kernel source, RFCs) or reproducible tests in this
   repo's environment. Forum hearsay does not overturn an official spec.
3. **Concede when wrong.** Adversaries are not graded on win rate. When a
   specialist's claim survives challenge, the adversary records the verification
   in their own notes — that's a contribution, not a loss.
4. **No personality, no point-scoring.** The adversaries critique claims, not
   agents. There is no "gotcha" reward.
5. **Adversaries challenge each other too.** The Fact Checker can verify a
   Devil's Advocate scenario against repo state; the Devil's Advocate can
   challenge the Fact Checker's choice of which claims to verify. The Old Man's
   anti-complexity counter-proposals are themselves fair targets — the Fact
   Checker can verify whether his "simpler alternative" actually works in this
   environment, and the Devil's Advocate can argue the simplification gives up
   something load-bearing.
6. **The Old Man has a specific obligation when challenging the IaC/DevOps
   Expert:** every objection is paired with a concrete alternative that meets
   the same requirement with less complexity, fewer dependencies, or less tech
   debt. "Don't do it" is not a counter-proposal. "Use a 20-line shell script
   in a cron job instead of standing up Workflow Engine X" is.

---

## Notes Protocol

Every agent's notes file follows the same template (see `docs/agent-notes/_TEMPLATE.md`). The protocol is the same for everyone:

### 1. Header timestamp

Every notes file has a YAML frontmatter block at the top:

```yaml
---
agent: <Agent Name>
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-03T23:42:42Z
---
```

- `last_updated_utc` is bumped any time the agent appends new content.
- `last_compacted_utc` is bumped only when the agent reorganizes/compacts.

### 2. Append on encounter

When an agent encounters new information, a useful source, or a development relevant to its specialization, it **appends** an entry under the appropriate section with a UTC timestamp. Append-only is the default — preserve raw observations.

### 3. Autonomous compaction every 24 h

Before doing any other substantive work, every agent **must check `last_compacted_utc`**. If it is more than 24 hours old (compared to current UTC), the agent compacts its notes **before continuing the user's task**:

1. Read the entire notes file.
2. Merge duplicate observations, promote stable findings into the "Settled knowledge" section, archive resolved items, drop noise.
3. Verify any specific claims (file paths, flags, package versions) still hold against the current repo state — stale claims are corrected or deleted, not preserved.
4. Update `last_compacted_utc` to current UTC.
5. Then proceed with the original task.

This prevents the notes from becoming a chronological log nobody reads.

### 4. Source-seeking is encouraged

Agents are expected to fetch primary sources when their existing notes don't cover a question — vendor docs, kernel docs, manpages, upstream issue trackers, RFCs, Raspberry Pi forums for the Pi Expert, the Arch/Debian wikis for the Linux Expert, etc. **Document the source** in the "Sources" section with:

- A one-line summary of what it covers
- The URL
- The date accessed (UTC)
- A confidence note (official docs > vendor blog > forum thread > random Stack Overflow answer)

Tooling preference order for lookups: `WebFetch` for known URLs, `WebSearch` for discovery, Context7 / `docs-lookup` agent for library API references.

### 5. Notes are version-controlled

These files are committed to git. Treat them as durable artifacts: no secrets, no scratch noise, no ephemeral debug output. If something is too rough to commit, it doesn't belong in the notes.

---

## Directory layout

```
docs/agent-notes/
├── _TEMPLATE.md                       # Copy this when adding a new agent
├── linux-expert-notes.md
├── raspberry-pi-expert-notes.md
├── old-man-notes.md
├── iac-devops-expert-notes.md
├── fact-checker-notes.md              # Adversarial — verifies factual claims
└── devils-advocate-notes.md           # Adversarial — challenges design and reasoning
```

To add a new agent: copy `_TEMPLATE.md`, fill in the frontmatter, register in this file's roster table, and link from the "When to invoke which agent" section.
