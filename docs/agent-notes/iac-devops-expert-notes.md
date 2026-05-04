---
agent: IaC/DevOps Expert
specialization: Packer, Ansible, FluxCD/GitOps, k3s, MetalLB, GitHub Actions, SOPS+age, Docker Compose
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-04T00:14:00Z
---

# IaC/DevOps Expert — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Anything that crosses the line between "code in the repo" and "running
on a host." Build systems, CI/CD, GitOps reconciliation, secrets, image
distribution, cluster bring-up, observability of the IaC pipeline itself.

---

## Settled knowledge

### Build → distribute → consume pipeline

```
git push (main, Hyperion/packer/**)
  → GitHub Actions (Packer + QEMU on ubuntu-latest)
  → GitHub Releases  (tags: node-v<EPOCH>, bootstrap-latest)
       ↓ (polled every 5 min)
  → ci-deploy container on Monolith
  → /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}/
  → nginx :50011 (LAN-only)
  → Pi nodes: bootstrap.sh updates HYPERION-ID USB cache → flashes NVMe
```

**Concurrency:** Both image workflows share `concurrency: build-images` so they
serialize. Don't break this — parallel publishes can race the manifest update.

### Secrets

- Only one required GitHub Actions secret: `NODE_SSH_PUBLIC_KEY`. CI uses the
  auto-provided `GITHUB_TOKEN` for releases.
- The Monolith-deploy-key approach in the design doc was **abandoned**. Monolith
  pulls from GitHub Releases via `ci-deploy`; CI never SSHes anywhere.
- SOPS + age for in-repo secrets. Public key in `Hyperion/.sops.yaml`, private
  key only at `~/.config/sops/age/keys.txt` on the workstation.

### Versioning

- Node IMG version = Unix epoch integer in `/boot/firmware/node-img.ver`.
- `manifest.json` published alongside the image; bash compares with `-gt`/`-ge`
  directly. Don't move to semver — the integer comparison is load-bearing in
  `bootstrap.sh`.

### Cluster status (per `docs/todo.md`)

- Monolith stack (k3s server + nginx + ci-deploy + healthcheck) is implemented.
- Packer images, CI workflows, identity USB tooling, EEPROM tooling, reimage
  tooling — all implemented.
- **Not yet done:** k3s+FluxCD bring-up (Step 10). MetalLB manifests exist under
  `Hyperion/k8s/infrastructure/metallb/` but no FluxCD reconciliation is wired
  yet. "GitOps reconciles the cluster" is aspirational.

### Healthcheck API

`http://192.168.10.247:50012/` — runs `Monolith/k3s-control-plane/healthcheck/healthcheck.py`.
Endpoints: `/` (full), `/summary`, `POST /scan` (rescan). Treats each IaC check as
a discrete test case with consecutive-pass/fail counts. Adding a check: decorate
a function with `@check(name, category, description)`.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-04T00:14:00Z — bootstrap.sh has an early-reboot branch that produces a boot loop on the bootstrap medium

`Hyperion/packer/files/bootstrap.sh:396` — when `NVME_VER >= USB_VER` the script jumps directly to `systemctl reboot` (line 403) without flashing. With EEPROM `BOOT_ORDER=0xf641` (SD → USB → NVMe), if the bootstrap medium is still inserted, the Pi reboots back into the bootstrap, runs the script again, and re-reboots — an infinite loop until the operator removes the medium. Combined with the `cleanup()` trap killing the status server (lines 196–203) immediately before the reboot, the operator sees HTTP 8080 → 404 → "stuck" — when actually the script ran cleanly. **Observability gap**: there is no human-visible signal that "I am about to reboot because flash isn't needed; remove the bootstrap medium." Filed under hypothesis #1 in the dbg-nvme-not-flashing pipeline run.

### 2026-05-04T00:14:00Z — `cleanup()` trap kills the status server before the EXIT message reaches the operator

`bootstrap.sh:196–210` — the EXIT trap unconditionally kills `STATUS_SERVER_PID`. So whenever the script exits — success, die, or `exec /bin/bash` after MAX attempts — the HTTP 8080 endpoint goes 404. The operator cannot distinguish between the success-reboot path, the die-with-SOS path, and the give-up-and-shell path from the HTTP signal alone. Recommend: keep the status server alive longer, with a populated terminal status, before the script exits. Tracked in fix plans for hypotheses #1 and #2 of the dbg-nvme-not-flashing pipeline run.

### 2026-05-04T00:14:00Z — `flash-identity-usb.sh` creates an EMPTY `node-image/` cache

`Hyperion/flash-identity-usb.sh:97–99` deliberately leaves the cache empty ("bootstrap will populate on first run"). This means a freshly-prepared identity USB has `USB_VER=0` until the first successful network fetch. If Monolith is unreachable on first boot AND the cache is empty, `bootstrap.sh:376` dies. This is a real failure path that the docs do not warn about. Recommend: `flash-identity-usb.sh` could optionally pre-populate the cache from a local copy of the latest `.img` if one is supplied as a third arg.

### 2026-05-04T00:14:00Z — ci-deploy poll.sh prune ordering can leave manifest pointing at a deleted file

`Monolith/k3s-control-plane/ci-deploy/poll.sh:140–154` writes the manifest at line 140 and prunes `.img` files at line 154 (`tail -n +4 | xargs rm -f`). On a single iteration this is fine because the new file is the most recent and survives the prune. But under rapid successive releases (e.g., back-to-back workflow_dispatch + push triggering two builds despite the `concurrency: build-images` group), the prune could remove the newly-published `.img` if the polled iteration is interleaved with a manual file-delete. Low likelihood in practice. Filed as hypothesis #5.

### 2026-05-04T00:14:00Z — Promtail EOL March 2, 2026 — Vector + Loki is the live path

Confirmed via Grafana official docs (https://grafana.com/docs/loki/latest/send-data/promtail/, accessed 2026-05-04). Promtail end-of-life as of March 2, 2026; commercial support ended; all future feature development in Grafana Alloy. For the Hyperion log-collection design proposed in dbg-nvme-not-flashing, choosing **Vector** (single static binary, ARM64 native, journald source, disk-backed buffer) over Promtail/Alloy gives operational uniformity with one config language (VRL) and one binary on every Pi. Loki monolithic mode (`-target=all`) on Monolith is sized for "small read/write volumes of up to approximately 20GB per day" per Grafana docs (https://grafana.com/docs/loki/latest/get-started/deployment-modes/, accessed 2026-05-04) — comfortably above our 10-Pi load.

---

## Sources

- **Packer arm-image plugin (solo-io)** — the plugin used to build Pi images
  via QEMU on x86_64 runners.
  https://github.com/solo-io/packer-plugin-arm-image — accessed 2026-05-03 —
  confidence: community (de facto standard)
- **k3s docs** — installation, agent join, kubeconfig.
  https://docs.k3s.io — accessed 2026-05-03 — confidence: official
- **FluxCD docs** — bootstrap, kustomization, SOPS integration.
  https://fluxcd.io/flux/ — accessed 2026-05-03 — confidence: official
- **MetalLB L2 mode** — IP pool + L2 advertisement (matches manifests under
  `Hyperion/k8s/infrastructure/metallb/`).
  https://metallb.universe.tf/configuration/ — accessed 2026-05-03 —
  confidence: official
- **SOPS** — age recipient configuration via `.sops.yaml`.
  https://github.com/getsops/sops — accessed 2026-05-03 — confidence: official
- **GitHub Actions concurrency** — `concurrency.group` semantics for serializing
  workflow runs.
  https://docs.github.com/en/actions/using-jobs/using-concurrency — accessed
  2026-05-03 — confidence: official
- **Vector `journald` source** — daemon-role, at-least-once, supports ARM64/Pi,
  reads via `journalctl` subprocess, requires `systemd-journal` group
  membership, persists checkpoint to `data_dir`.
  https://vector.dev/docs/reference/configuration/sources/journald/ — accessed
  2026-05-04 — confidence: official (Datadog/Timber)
- **Loki deployment modes** — monolithic mode (`-target=all`) sized for ~20 GB/day
  with filesystem storage; appropriate for the Monolith aggregator.
  https://grafana.com/docs/loki/latest/get-started/deployment-modes/ — accessed
  2026-05-04 — confidence: official (Grafana)
- **Promtail EOL** — end of life March 2, 2026; migrate to Alloy or another
  supported client. Drives our choice of Vector over Promtail.
  https://grafana.com/docs/loki/latest/send-data/promtail/ — accessed
  2026-05-04 — confidence: official (Grafana)

---

## Archive
