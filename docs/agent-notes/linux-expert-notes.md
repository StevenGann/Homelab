---
agent: Linux Expert
specialization: Debian/Trixie, systemd, networking, filesystems, kernel, package management, shell
last_compacted_utc: 2026-05-21T15:00:00Z
last_updated_utc:   2026-05-21T15:00:00Z
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

### Hyperion-specific repo facts

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
- Bootstrap medium runs sshd as `pi:raspberry` — useful live-debug lever
  (`Hyperion/packer/rpi-bootstrap.pkr.hcl:84-100`).
- `bootstrap.sh:396` guard `[ "$NVME_VER" -ge "$USB_VER" ]` short-circuits when
  both default to `0`. Documented root cause for the May-2026 "SSD not flashing"
  symptom. Fix: require `NVME_VER -gt 0` for the skip-flash branch.
- Bootstrap medium uses **dhcpcd** (Pi OS Lite default), not systemd-networkd, so
  `systemd-networkd-wait-online.service` is a no-op and
  `network-online.target` resolves prematurely; the `NET_WAIT=60` polling loop
  added in commit `8a21d6b` only checks for a default route, not reachability.
- Bootstrap medium has **no static DNS server in the IMG**. dhcpcd populates
  `/etc/resolv.conf` from DHCP options 6/15 (UCG-supplied). With Trixie's stock
  dhcpcd (the Pi-customized dhcpcd5 from Bookworm was dropped), the only DNS
  available pre-mount-of-USB is whatever the UCG hands out — so bootstrap.sh's
  `MONOLITH_BASE` cannot use a hostname unless that hostname is also resolvable
  via the UCG's upstream DNS path. **At the moment, only literal IPs work
  during bootstrap.**
- `systemd-journal-upload` is the canonical Homelab log-shipping mechanism.
  Both Hyperion image variants enable it and push to `http://192.168.10.247:19532`
  via a drop-in at `/etc/systemd/journal-upload.conf.d/monolith.conf`. Package on
  Trixie is `systemd-journal-remote` (sender + receiver come in the same pkg).
  Default TCP port 19532.
- Bootstrap.sh `:8080` status server: serves `/` (JSON status from
  `/tmp/bootstrap-status.json`) and `/log` (tail of `bootstrap.log` on the
  HYPERION-ID USB at `$CACHE_DIR/bootstrap.log`). Survives `MAX_BOOT_ATTEMPTS`
  by being started **before** the gate; `exec /bin/bash` reparents to PID 1
  and keeps serving the `exhausted_attempts` state.
- Two IP references to update for Heimdall migration:
  - `Hyperion/packer/files/bootstrap.sh:32`: `MONOLITH_BASE=...:50011`
  - `Hyperion/packer/rpi-bootstrap.pkr.hcl:131`: `URL=...:19532`
  - `Hyperion/packer/rpi-node.pkr.hcl:245`: `URL=...:19532`

### Monolith-specific repo facts

- Static host (TrueNAS Scale), Docker Compose stack at
  `Monolith/k3s-control-plane/docker-compose.yml`. Pattern: static OS, bind-mounted
  config from `/mnt/.../Container-Data/...`, services pulled from
  `ghcr.io/stevengann/homelab-*`.
- `journal-remote` container baked from `debian:trixie-slim` (Dockerfile in repo).
  Listens HTTP on `:19532`. Writes to `/var/log/journal/remote/` with
  `--split-mode=host` → one `remote-<hostname>.journal` file per source.
- Image registry: nginx on `:50011`, served from `/mnt/Media-Storage/Infra-Storage/images`.
- ci-deploy poller: `homelab-ci-deploy` polls GitHub Releases every 5 min, writes
  to `/images` (= `/mnt/Media-Storage/Infra-Storage/images` on host).
- healthcheck API on `:50012/summary` (out of scope for this migration).

### Heimdall-specific repo facts (settled)

- Ubuntu Server 26.04 LTS "Resolute Raccoon" (systemd 259, cgroup v2 only,
  dracut default initrd).
- Docker CE from upstream `download.docker.com` apt repo (resolute suite).
  daemon.json sets `log-driver: journald`, `live-restore`, `userland-proxy: false`.
- nftables ruleset at `Heimdall/hostconf/nftables.conf` (installed to
  `/etc/nftables.conf`). Table `inet heimdall_fw`. Default-deny inbound;
  per-port LAN-allow rules. `forward` chain policy `accept` so Docker bridge
  networking works.
- `systemd-journal-upload` configured on Heimdall via
  `Heimdall/hostconf/journal-upload-monolith.conf` → ships TO Monolith:19532.
- `systemd-resolved` runs with `DNSStubListener=no` so containers can bind :53
  (Technitium under `network_mode: host`).
- Compose stack lives at `/opt/Homelab/Heimdall/docker-compose.yml`.
  Persistent state under `/opt/Homelab/Heimdall/{komodo-data,technitium,caddy,secrets}/`.
- Komodo Periphery is **host systemd binary**, not a container (avoids the
  container-manager-managing-the-container-manager-managing-itself loop).
- `Heimdall/scripts/deploy.sh` is the canonical one-command deploy from the
  workstation: SOPS-decrypt → ssh-ship → git pull → compose pull → up -d →
  onboard-periphery → seed-zones → seed-blocklists.
- Caddy with caddy-l4 plugin, in `network_mode: host` for L4 source-IP
  preservation. Internal CA root distributed via `http://heimdall.lab/ca.crt`
  on :80.

### General sysadmin knowledge worth keeping

- `systemd-journal-upload.service` — Debian package `systemd-journal-remote`;
  config `/etc/systemd/journal-upload.conf` plus drop-ins under
  `/etc/systemd/journal-upload.conf.d/*.conf`. Default port 19532. Tolerates
  receiver outages — buffers locally up to `Storage.MaxSize`.
- `systemd-journal-remote` with `--split-mode=host` writes
  `remote-<escaped-hostname>.journal` per upload source. The "hostname" is the
  endpoint of the TCP connection (DNS reverse-lookup, or literal IP). Per
  upstream PR #2080, the port is stripped from the filename so connection
  resets don't fragment into a new file. **The `_HOSTNAME=` field inside
  individual journal entries comes from the source machine; `journalctl
  _HOSTNAME=hyperion-alpha` filters by that, independent of filename.**
- `journalctl --directory=<dir> -f` follows a remote journal directory in real
  time (refresh-on-mtime; new files in the dir are picked up).
- Trixie systemd-resolved interaction: stub listener at `127.0.0.53:53`. If the
  host needs to *host* a DNS server on `:53`, `systemd-resolved` must be either
  disabled or configured with `DNSStubListener=no`.
- Caddy `reverse_proxy` SSE/streaming: set `flush_interval -1` to disable
  response buffering. Auto-detected for `Content-Type: text/event-stream`
  since v2.8, but explicit setting is safer. Bug if `encode` (compression)
  is enabled upstream sends only headers — exclude streaming routes from
  `encode`.
- Docker bridge `ports:` mappings rewrite source IPs via `docker-proxy` (fine
  for HTTP-with-XFF, broken for L4). Fix: `network_mode: host` OR
  `userland-proxy: false`.
- `sed -i` on Linux replaces the inode and inherits caller's umask. Mode/owner
  changes — re-apply explicit `chmod`/`chown` after sed on system config files.
- Pi OS Trixie ships **stock Debian dhcpcd** (Bookworm's dhcpcd5 was Pi-modified).
  No automatic resolvconf installation by default; `/etc/resolv.conf` is
  populated directly by dhcpcd's 20-resolv.conf hook from DHCP options 6/15.
  Disable per-script with `nohook`.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-21T15:00:00Z — Stage 1 research for dev-hyperion-flashing-to-heimdall

Run `20260521T144651Z-dev-hyperion-flashing-to-heimdall`. Wrote
`docs/pipeline-runs/20260521T144651Z-dev-hyperion-flashing-to-heimdall/01-proposals/linux-expert.md`.

Linux/host-OS lens findings on the migration to Heimdall:

- **Three services added to Heimdall's stack**: nginx (`:50011`), ci-deploy
  (no port — outbound only to GitHub), journal-remote (`:19532` plain HTTP).
  None conflict with the existing four-container stack (mongo / komodo-core
  on `127.0.0.1:9120` / technitium host-net on 53/5380/853 / caddy host-net
  on 80/443/443udp/25565). Compose bridge network handles all three.
- **nftables additions** are minimal (3 rules in the LAN-allowed input chain):
  `tcp dport 50011 accept`, `tcp dport 19532 accept`, plus optionally re-using
  existing `tcp dport 8080 accept`-equivalent for a flash dashboard. All
  source-restricted to `192.168.10.0/24` since this is LAN-only.
- **`network_mode: host` decision for journal-remote**: NO. With
  `split-mode=host`, the filename is `remote-<reverse-DNS-or-IP-of-source>`.
  Per upstream behavior, journal-remote does a hostname lookup on the source IP
  via libc resolver (NSS). On Heimdall the resolver hits the host's resolved
  → upstream DNS, so Pi reverse-PTRs will resolve through Technitium (once we
  register them) or fall back to literal IPs. **Bridge networking via `ports:
  19532:19532` does rewrite source IPs via docker-proxy**, but journal-remote
  doesn't use source IPs for anything load-bearing — `_HOSTNAME=` in journal
  entries comes from the SENDER's machine, not the TCP connection. The
  filename becomes `remote-172.17.0.1.journal` if we go bridge, which is
  harmless because we always query by `_HOSTNAME=` field. **But to keep the
  filename meaningful, set `userland-proxy: false` (already in Heimdall
  daemon.json — verified) and journal-remote sees the real source IP via the
  in-kernel NAT.** No host networking needed.
- **Storage**: Heimdall is single-disk. Per the existing compose pattern,
  bind-mount `/opt/Homelab/Heimdall/images/` (about 5 GB capacity ceiling for
  ~3 node images + 1 bootstrap image at zstd-compressed sizes). NFS-from-Monolith
  is rejected — circular dependency (Heimdall serves Pis from Monolith
  storage; if Monolith is down, Heimdall flash service is down too, which
  defeats half the migration's value).
- **journal-remote container vs host-installed**: container, same as Monolith.
  Heimdall **also** has host-installed `systemd-journal-upload` (sender, ships
  Heimdall's own journal TO Monolith). The two have similar package origins
  (`systemd-journal-remote` apt package on Debian/Ubuntu contains BOTH the
  receiver binary and the uploader binary) but distinct roles: upload =
  client/sender; remote = server/receiver. Naming collision is unavoidable;
  document explicitly.
- **Persistent data path for received journals**: `/opt/Homelab/Heimdall/journal-remote/`
  bind-mount, mirroring `/var/log/journal/remote/` inside the container.
  Backups extended via `Heimdall/scripts/backup.sh` to include this directory.
- **Realtime monitoring**: the `:8080` per-Pi status server is the obvious
  data source. Two-layer tool:
  1. **`watch-flash.sh <hostname>`** — workstation shell script. Resolves
     hostname to IP via known reservation table (Hyperion `:101–:110`,
     alpha→kappa). Polls `:8080/` + `:8080/log` every 2s, renders status +
     last 20 log lines. Single screen, watchable side-by-side with the
     bootstrap LED on the actual Pi.
  2. **`https://flash.heimdall.lab/<hostname>`** — Caddy-fronted lightweight
     CGI / static page that proxies to `:8080` of the Pi. Useful when SSH'd
     in from off-LAN via WireGuard.
  Both layered on top of the existing `:8080` server, no new instrumentation
  in bootstrap.sh.
- **Caddy SSE/streaming for the web dashboard**: if we add SSE later, must
  set `flush_interval -1` in the reverse_proxy block.
- **Cutover sequencing**:
  - Phase A: Stand up the three services on Heimdall **in parallel** with
    Monolith's existing services. Both endpoints alive simultaneously. nginx
    serves the same files (ci-deploy independently polls GitHub, both write
    to their local images dir).
  - Phase B: Reflash ONE Pi (hyperion-alpha) with a new Bootstrap IMG pointed
    at Heimdall. Verify with the realtime tool that everything works.
  - Phase C: Bake the Heimdall IPs into the Node IMG via CI. Roll out to
    remaining nodes one at a time using `./reimage.sh`.
  - Phase D: After all 10 nodes are confirmed running against Heimdall for
    ≥7 days, decommission Monolith's nginx/ci-deploy/journal-remote
    containers (`docker compose stop` first, then `docker compose rm` in
    Monolith).
  Monolith stays alive throughout. The two systems are independent;
  there's no rsync-from-Monolith requirement because ci-deploy on Heimdall
  pulls directly from GitHub.
- **Hostname vs IP in bootstrap.sh**: KEEP THE LITERAL IPs in v1. Pi
  bootstrap's DNS chain is dhcpcd → DHCP options 6/15 → UCG → upstream
  (eventually Technitium once Hyperion is operational, but on the Bootstrap
  medium the resolver path is UCG-direct). Hostname resolution for `images.lab`
  is not available during the early-bootstrap window because:
  1. The Bootstrap IMG never registers with Technitium for DNS — it has no
     `apply-identity.service` equivalent for DNS.
  2. UCG forwards `*.lab` to Heimdall via DNS-zone delegation only AFTER
     Heimdall's Technitium is the LAN's authoritative resolver — which
     depends on Heimdall being up.
  3. Even with all that, the chicken-and-egg risk during cutover is real:
     if Heimdall is the only `*.lab` resolver and Heimdall is down, no
     `images.lab` resolves and Pis can't bootstrap.
  Recommendation: literal IP (`192.168.10.4`) in bootstrap.sh; defer the
  hostname conversion to a v2 ticket once Technitium is the registered
  DHCP-DNS for the LAN AND we've validated UCG falls back to upstream
  resolvers on Heimdall outage.
- **Migration posture**: Heimdall is the **permanent** host for these three
  services. Rationale (Linux-lens): Heimdall is the modern Komodo-managed
  Ubuntu Server stack; Monolith is the legacy TrueNAS-on-bare-metal Compose
  stack; this migration is also a piece of the gradual decommissioning of
  Monolith as a control-plane host. The user said "temporarily" but the team's
  job is to surface that there's no Linux-side reason to plan a return trip.

Surprise: I expected to need to add a forward-chain rule for Docker, but
`forward { policy accept; }` is already there from Heimdall finalize. The
three new services need only their input-chain ports added.

---

## Sources

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
- **systemd-journal-remote.service(8)** — `--listen-http`, `--split-mode=host`,
  output filename `remote-<hostname>.journal`.
  https://www.freedesktop.org/software/systemd/man/latest/systemd-journal-remote.service.html
  — accessed 2026-05-21 — confidence: official
- **systemd PR #2080** — split-mode=host filename naming behavior; port
  stripped from filename.
  https://github.com/systemd/systemd/pull/2080/files — accessed 2026-05-21 —
  confidence: official upstream
- **dhcpcd(8) — Debian Trixie** — DHCP DNS option handling and resolvconf
  integration in stock Debian dhcpcd (post-Pi-customized-dhcpcd5).
  https://manpages.debian.org/trixie/dhcpcd-base/dhcpcd.8.en.html — accessed
  2026-05-21 — confidence: official
- **Caddy reverse_proxy directive (flush_interval)** — SSE / streaming
  buffering behavior; `flush_interval -1` low-latency mode.
  https://caddyserver.com/docs/caddyfile/directives/reverse_proxy — accessed
  2026-05-21 — confidence: official
- **Caddy issue #4247** — SSE buffering bug history; behavior verified in
  v2.8+.
  https://github.com/caddyserver/caddy/issues/4247 — accessed 2026-05-21 —
  confidence: official issue tracker
- **Ubuntu 26.04 LTS release notes** — feature set, kernel, systemd version.
  https://discourse.ubuntu.com/t/ubuntu-26-04-lts-resolute-rhino-release-notes/
  — accessed 2026-05-17 — confidence: official Canonical
- **Docker Engine install on Ubuntu** — upstream apt repo path, package set.
  https://docs.docker.com/engine/install/ubuntu/ — accessed 2026-05-17 —
  confidence: official vendor
- **Docker bind mounts** — read-only and rw bind-mount syntax in Compose;
  recursive-ro kernel ≥5.12.
  https://docs.docker.com/engine/storage/bind-mounts/ — accessed 2026-05-21 —
  confidence: official

---

## Archive
