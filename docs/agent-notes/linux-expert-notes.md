---
agent: Linux Expert
specialization: Debian/Trixie, systemd, networking, filesystems, kernel, package management, shell
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-04T00:15:00Z
---

# Linux Expert — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Anything below the application layer that runs on Linux: systemd units
and ordering, mount logic and udev, networking stack, filesystem choices, kernel
parameters, package management, shell idioms, and standard sysadmin reasoning.

---

## Settled knowledge

### Repo-specific facts worth remembering

- Node OS is **Debian Trixie (Pi OS Lite arm64)**. Trixie uses initramfs by default;
  `auto_initramfs=1` in `config.txt` is required for the Pi 5 boot path.
- `cloud-init` is **purged** from the Node IMG. Identity is set by
  `apply-identity.service` reading `/dev/disk/by-label/HYPERION-ID`. Do not
  reintroduce cloud-init.
- `/mnt/node-storage` is mounted **only** by `mnt-node-storage.mount`
  (systemd unit). Bootstrap deliberately does not write a fstab entry — duplicate
  mounts would create a unit conflict.
- Node detection logic: `detect-node-storage.service` writes a drop-in at
  `/run/systemd/system/mnt-node-storage.mount.d/override.conf` and runs
  `systemctl daemon-reload`. The override sets `What=` to the chosen device.
- SSH user on production nodes is `owner`. The default `pi` user is **deleted**
  during Packer build.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-04T00:15:00Z — bootstrap.sh version-comparison short-circuit

In `Hyperion/packer/files/bootstrap.sh:396` the guard is `if [ "$NVME_VER" -ge "$USB_VER" ]; then`.
Both default to `0` when their source files are missing (identity USB has no `node-image/version`,
NVMe has no `/boot/firmware/node-img.ver`). `0 -ge 0` is true → script jumps to "NVMe is current.
Rebooting" without flashing. This is the most likely root cause of the "SSD not flashing" symptom
in pipeline run `20260504T000719Z-dbg-nvme-not-flashing`. The fix is to require `NVME_VER -gt 0`
for the skip-flash branch.

### 2026-05-04T00:15:00Z — bootstrap medium runs sshd as pi:raspberry

`Hyperion/packer/rpi-bootstrap.pkr.hcl:84-100` enables sshd with hardcoded `pi:raspberry` on the
bootstrap image. This is the primary live-debug lever for any future bootstrap-failure investigation
— SSH in while the failure is happening, read journal + status JSON + identity USB contents in real
time. Document: prefer Experiment A (live SSH) over Experiment B (post-mortem USB inspection)
whenever the node is still reachable.

### 2026-05-04T00:15:00Z — dhcpcd vs systemd-networkd-wait-online race on Pi OS Trixie

The bootstrap medium uses **dhcpcd** (Pi OS Lite default), not systemd-networkd. So
`systemd-networkd-wait-online.service` is a no-op (no networkd-managed interfaces) and returns
immediately, satisfying `network-online.target` instantly. This was the motivation for the
`NET_WAIT=60` polling loop added in commit `8a21d6b`. The loop only checks for a default route, not
for actual reachability of Monolith — DNS/route can be half-baked for a few extra seconds after the
default route appears. Stronger check: include a `curl -sf $MANIFEST_URL` in the readiness loop.

---

## Sources

<!-- Add sources here as they're consulted -->

- **systemd.mount(5)** — canonical reference for mount unit syntax and ordering.
  https://www.freedesktop.org/software/systemd/man/systemd.mount.html — accessed
  2026-05-03 — confidence: official
- **Debian Trixie release notes** — current stable release, kernel/init changes.
  https://www.debian.org/releases/trixie/releasenotes — accessed 2026-05-03 —
  confidence: official
- **systemd-journal-upload.service(8) — Debian Trixie** — confirms package is
  `systemd-journal-remote`, default TCP port 19532, config files
  `/etc/systemd/journal-upload.conf` and `/etc/systemd/journal-remote.conf`.
  https://manpages.debian.org/trixie/systemd-journal-remote/systemd-journal-upload.service.8.en.html
  — accessed 2026-05-04 — confidence: official Debian manpage

---

## Archive
