---
agent: <Agent Name>
specialization: <one-line description>
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-03T23:42:42Z
---

# <Agent Name> — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

---

## Settled knowledge

Stable, verified findings that survived compaction. Organized by topic, not by date.

<!-- Promote items here once they've been confirmed and are unlikely to change. -->

---

## Active observations

Recent encounters that haven't been compacted yet. Append new items at the bottom
with a UTC timestamp prefix: `### YYYY-MM-DDTHH:MM:SSZ — short title`.

<!-- Append-only working area. Compaction moves items into Settled or Archive. -->

---

## Sources

External references cited or used. Format:

- **<Title>** — one-line summary. <URL> — accessed YYYY-MM-DD — confidence: <official|vendor|community|low>

<!-- Add sources here whenever you fetch or cite external material. -->

---

## Archive

Resolved or superseded items kept for historical context.

<!-- Compaction moves obsolete-but-historically-useful items here. Delete the truly dead. -->
