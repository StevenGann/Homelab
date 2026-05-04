---
agent: Fact Checker
specialization: Empirical verification of claims against primary sources or reproducible tests
role: Adversarial — every other agent's claims are targets
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-04T00:35:00Z
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

## Verdicts ledger

Format per entry:

```
### YYYY-MM-DDTHH:MM:SSZ — <short claim summary>
- Claim: <verbatim or close paraphrase, with the source agent + file:line if available>
- Verdict: CONFIRMED | REFUTED | UNVERIFIED | PARTIAL
- Evidence: <command output, doc URL + quoted passage, or test result>
- Implication: <what changes in the repo or notes if the verdict is REFUTED/PARTIAL>
```

<!-- Append new verdicts at the bottom. Compaction merges duplicates and retires
     verdicts whose subject is no longer in the repo. -->

### 2026-05-04T00:35:00Z — Pipeline run `20260504T000719Z-dbg-nvme-not-flashing` iter-1, combined-draft adversarial review

Full ledger written to `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/03-adversarial/fact-checker.md` (V-1 through V-22). Highlights:

- **REFUTED — V-1: Old Man H5 sub-finding "latent reflash-loop bug" (Node IMG missing `node-img.ver`).**
  bootstrap.sh:422 deletes `node-img.ver` and never rewrites it (CONFIRMED), but `Hyperion/packer/rpi-node.pkr.hcl:117` (provisioner step "── 7. Write version stamp ──") writes `echo '${var.image_version}' > /boot/firmware/node-img.ver` at Packer build time. The "perpetual reflash loop" antecedent is FALSE in the current repo state. The combined draft's §5 "If H5 sub-bug confirmed" branch and §8 pre-flight item #2 should be downgraded from "latent bug hunt" to "verify-only".

- **PARTIAL — V-12: Combined draft §1 description of `MAX_BOOT_ATTEMPTS` exec → "child server orphaned and dies".**
  Empirically verified: `exec` does NOT fire EXIT trap. The Python child would be reparented to PID 1, not killed. But it doesn't matter because `_start_status_server` is at line 232, downstream of the `exec /bin/bash` at line 226 — so on attempt 4+ the HTTP server was never started in this boot. H3's symptom signature ("connection-refused from boot, never returns 200") stands; the explanatory mechanism in §1 should be reworded to "process replaced before the server was ever started" instead of "orphaned and dies".

- **CONFIRMED — V-2 through V-9, V-11, V-13 through V-19, V-21, V-22:** All file-line citations to bootstrap.sh and rpi-node.pkr.hcl verified by direct read. `0 -ge 0` returns true (V-7) verified empirically. EXIT trap fires on SIGTERM (V-13) verified empirically. rpi-eeprom #629 (V-14) and #718 (V-15) GitHub issues exist with titles and content matching the Pi Expert's claims. Promtail EOL March 2 2026 (V-16) confirmed against official Grafana docs. Commit 8a21d6b (V-18) is real. No prior pipeline runs (V-19) confirmed.

- **PARTIAL — V-15:** Issue #718 says `sudo reboot` (which under systemd resolves to `systemctl reboot`); equivalence holds, no draft change needed.

- **PARTIAL — V-17:** "256 GB SSDs per CLAUDE.md" — the figure appears in the agent's project memory (`~/.claude/projects/.../memory/project_hyperion_hardware.md`), NOT in the repo's CLAUDE.md. Repo CLAUDE.md and `docs/todo.md` together imply ~256 GB via partition arithmetic but don't state the size explicitly. Citation should be tightened.

- **PARTIAL — V-20:** `rpi-bootstrap.pkr.hcl:96–98` covers SSH activation; the `pi:raspberry` password setup is at line 92.

- **PARTIAL — V-11:** `flash-identity-usb.sh:97-99` cites the `mkdir -p` for the cache dir; the operator-facing "empty cache" acknowledgment is at line 109.

Additional independent observation logged in V-13 (not a refutation): in the "NVMe is current" path (line 396-404), the script does NOT `exit` after `systemctl reboot`. Control falls through to step 6 (Flash NVMe at line 406). `systemctl reboot` is asynchronous so a subtle race exists where line 411's `dd` could begin before systemd-shutdown terminates the unit. Window is small but non-zero. Not load-bearing for the user's reported symptom but worth flagging for the fix-plan stage.

---

## Standing watch list

Claims worth periodically re-verifying because the underlying source can change.

- **`BOOT_ORDER=0xf641` nibble meaning** — Pi bootloader docs occasionally
  reorganize. Re-verify against the bootloader-config page when the Pi Expert's
  notes are touched.
- **`dtparam=pciex1_gen=3` is an overclock (spec is Gen 2)** — Raspberry Pi
  could revise the spec. Re-verify against official Pi 5 / M.2 HAT documentation
  on each Pi-Expert compaction.
- **`auto_initramfs=1` required on Trixie** — verify against the Pi OS
  release notes for the current Trixie image being used in `rpi-node.pkr.hcl`.
- **`ci-deploy` poll interval = 300 s** — claimed in multiple docs. Verify
  against `Monolith/k3s-control-plane/docker-compose.yml` env (`POLL_INTERVAL`)
  and the ci-deploy image's actual behavior.
- **Only `NODE_SSH_PUBLIC_KEY` is a required Actions secret** — verify against
  the actual workflow YAML files under `.github/workflows/` whenever they're
  modified.

---

## Verification toolkit

Preferred order of evidence, strongest first:

1. **Read the file in this repo.** `Read` tool, with `file_path:line_number`
   citation. Beats every external source for repo-specific claims.
2. **Run the command.** `Bash` tool — `rpi-eeprom-config`, `lsblk -J`,
   `systemctl cat`, `gh release list`, `curl -sf`, etc. Capture exact output.
3. **Vendor / project documentation.** Official URL + quoted passage + access
   date. Use `WebFetch` for known URLs.
4. **Source code of the upstream project.** Linked to a specific commit or tag.
5. **RFC or standards document.** With section number.
6. **Manpage.** `man <thing>` — note the section.

Anything below this — forum threads, Stack Overflow, Reddit, vendor blog posts —
is **circumstantial**. It can motivate a check but cannot conclude one.

---

## Sources (verification references)

- **Raspberry Pi bootloader configuration** — authoritative `BOOT_ORDER` reference.
  https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration —
  accessed 2026-05-03 — confidence: official
- **`config.txt` reference** — every directive, including `dtparam` and
  `auto_initramfs`. https://www.raspberrypi.com/documentation/computers/config_txt.html —
  accessed 2026-05-03 — confidence: official
- **systemd.mount(5) / systemd.unit(5)** — for verifying mount-unit and ordering
  claims. https://www.freedesktop.org/software/systemd/man/ — accessed 2026-05-03 —
  confidence: official
- **GitHub REST API — Releases** — for verifying ci-deploy poller assumptions.
  https://docs.github.com/en/rest/releases/releases — accessed 2026-05-03 —
  confidence: official
- **k3s docs** — for k3s-related claims (token handling, kubeconfig, agent join).
  https://docs.k3s.io — accessed 2026-05-03 — confidence: official

---

## Archive

Verdicts whose subject was removed from the repo, or that were superseded by a
later verification. Kept for historical context.
