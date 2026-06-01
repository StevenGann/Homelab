---
agent: Linux Expert
specialization: Debian/Trixie, systemd, networking, filesystems, kernel, package management, shell
last_compacted_utc: 2026-05-21T15:00:00Z
last_updated_utc:   2026-05-23T07:00:00Z
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
  `AKASHA_BASE` cannot use a hostname unless that hostname is also resolvable
  via the UCG's upstream DNS path. **At the moment, only literal IPs work
  during bootstrap.**
- `systemd-journal-upload` is the canonical Homelab log-shipping mechanism.
  Both Hyperion image variants enable it and push to `http://192.168.10.247:19532`
  via a drop-in at `/etc/systemd/journal-upload.conf.d/akasha.conf`. Package on
  Trixie is `systemd-journal-remote` (sender + receiver come in the same pkg).
  Default TCP port 19532.
- Bootstrap.sh `:8080` status server: serves `/` (JSON status from
  `/tmp/bootstrap-status.json`) and `/log` (tail of `bootstrap.log` on the
  HYPERION-ID USB at `$CACHE_DIR/bootstrap.log`). Survives `MAX_BOOT_ATTEMPTS`
  by being started **before** the gate; `exec /bin/bash` reparents to PID 1
  and keeps serving the `exhausted_attempts` state.
- Two IP references to update for Heimdall migration:
  - `Hyperion/packer/files/bootstrap.sh:32`: `AKASHA_BASE=...:50011`
  - `Hyperion/packer/rpi-bootstrap.pkr.hcl:131`: `URL=...:19532`
  - `Hyperion/packer/rpi-node.pkr.hcl:245`: `URL=...:19532`

### Akasha-specific repo facts

- Static host (TrueNAS Scale), Docker Compose stack at
  `Akasha/k3s-control-plane/docker-compose.yml`. Pattern: static OS, bind-mounted
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
  `Heimdall/hostconf/journal-upload-akasha.conf` → ships TO Akasha:19532.
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

### 2026-06-01T00:00:00Z — Stage 1 research for dev-arr-stack (NFS lens)

Run: arr-stack DEVELOPMENT pipeline. Proposal returned to orchestrator (not written to file per subagent rules).

NFS / TrueNAS facts verified this session (promote to settled after compaction):

- **TrueNAS NFS export = exactly ONE dataset/path; a ZFS *child dataset* is NOT
  traversed by default.** TrueNAS docs: "NFS treats each dataset as its own
  file system… the client cannot access any nested or child datasets beneath
  the parent." This is the load-bearing correction to the baseline plan: the
  "one dataset, exported once, hardlinks work" design ONLY holds if
  `torrents/` and `media/` are plain **directories inside a single dataset**,
  NOT separate child datasets. If they are child datasets, the client sees the
  child mountpoints as empty dirs and writes land on the PARENT dataset
  (different fsid) → hardlink/atomic-move silently breaks → *arr copy+delete.
  `crossmnt`/`nohide` would expose children but each child is still a SEPARATE
  fsid → hardlinks across them STILL fail. So the rule is: ONE dataset, the
  TRaSH tree is DIRECTORIES (mkdir), never `zfs create` per subtree.
- **mapall vs maproot (TrueNAS):** Mapall User/Group squashes EVERY connecting
  client identity to that user/group regardless of the incoming UID — this is
  Linux kernel-nfsd `all_squash` + `anonuid=/anongid=`. Maproot only squashes
  root. They are mutually exclusive; Mapall supersedes Maproot. Mapall=1000/1000
  makes the Pi-side PUID irrelevant for ownership ON DISK (everything written is
  owned 1000:1000 on Akasha) — sidesteps the NFSv4 idmap asymmetry below.
- **NFSv4 AUTH_SYS idmap is asymmetric** (Launchpad #966734, nfs-ganesha ID
  Mapping wiki): server→client name mapping works, client→server often does not;
  with AUTH_SYS the on-create owner derives from the numeric RPC creds. Net:
  don't rely on NFSv4 idmapd domain matching across hosts — use `mapall`
  (all_squash) and you don't care about idmap at all. Avoids the classic
  "files show as `nobody`/`4294967294`" trap.
- **nconnect:** multiple TCP connections per mount over ONE server IP,
  round-robin. NetApp testing: nconnect=8 most performant; nconnect=4 the common
  k8s default. Available for NFSv4.1 by default on modern clients. Safe in PV
  `mountOptions`. Pi 5 single-NIC 1GbE will saturate well before TCP-connection
  count matters, so nconnect=4 is fine/marginal here.
- **SQLite over NFS = corruption.** POSIX fcntl advisory locks unreliable over
  NFS; WAL `-shm` is an mmap'd shared-memory file that does NOT work over NFS at
  all. Confirmed by Sonarr #2797/#1886, SQLite lockingv3 doc. → every *arr
  `/config` MUST be local-path (node-local), NEVER the NFS PVC. Baseline already
  says this; it is non-negotiable.
- **NFS `hard` mount + k8s `Recreate`:** hard mount means I/O retries forever if
  Akasha is down — the pod hangs in D-state rather than corrupting. Combined
  with RWO local-path config + `Recreate`, the pod is pinned to one node and a
  reschedule won't double-mount. Good. Add `noatime` to cut metadata writes.
- **seerr-team/seerr** (operator-locked successor): `ghcr.io/seerr-team/seerr`,
  manifest includes linux/arm64; runs as UID 1000 (node user, NO PUID env —
  same model as jellyseerr); config dir `/app/config` (databases+logs live
  there → MUST be local-path, it's SQLite too). Currently only `develop` +
  `sha-*` tags published (no semver release tag yet) — pin a `sha-<digest>` tag.
- **Tdarr server arm64:** `ghcr.io/haveagitgat/tdarr` IS multi-arch (amd64 +
  armv8). The `tdarr` image is Server+internal Node; set `internalNode=false`
  to keep transcode off the Pi. External worker connects to `serverURL`
  `http://<server-ip>:8266`; UI 8265, server/node port 8266. Both must be
  LAN-reachable for the Thoth worker → server needs the MetalLB LB IP, not
  ClusterIP. serverIP=0.0.0.0 inside the container.

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
  ~3 node images + 1 bootstrap image at zstd-compressed sizes). NFS-from-Akasha
  is rejected — circular dependency (Heimdall serves Pis from Akasha
  storage; if Akasha is down, Heimdall flash service is down too, which
  defeats half the migration's value).
- **journal-remote container vs host-installed**: container, same as Akasha.
  Heimdall **also** has host-installed `systemd-journal-upload` (sender, ships
  Heimdall's own journal TO Akasha). The two have similar package origins
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
    Akasha's existing services. Both endpoints alive simultaneously. nginx
    serves the same files (ci-deploy independently polls GitHub, both write
    to their local images dir).
  - Phase B: Reflash ONE Pi (hyperion-alpha) with a new Bootstrap IMG pointed
    at Heimdall. Verify with the realtime tool that everything works.
  - Phase C: Bake the Heimdall IPs into the Node IMG via CI. Roll out to
    remaining nodes one at a time using `./reimage.sh`.
  - Phase D: After all 10 nodes are confirmed running against Heimdall for
    ≥7 days, decommission Akasha's nginx/ci-deploy/journal-remote
    containers (`docker compose stop` first, then `docker compose rm` in
    Akasha).
  Akasha stays alive throughout. The two systems are independent;
  there's no rsync-from-Akasha requirement because ci-deploy on Heimdall
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
  Ubuntu Server stack; Akasha is the legacy TrueNAS-on-bare-metal Compose
  stack; this migration is also a piece of the gradual decommissioning of
  Akasha as a control-plane host. The user said "temporarily" but the team's
  job is to surface that there's no Linux-side reason to plan a return trip.

Surprise: I expected to need to add a forward-chain rule for Docker, but
`forward { policy accept; }` is already there from Heimdall finalize. The
three new services need only their input-chain ports added.

### 2026-05-23T05:01:33Z — Stage 1 research for nixos-identity-usb DEVELOPMENT pivot

Run `20260523T050133Z-dev-nixos-identity-usb`. User wants to abandon
Packer+Debian Node-IMG-reflash for NixOS-flashed-once + per-host config on
identity USB. Wrote proposal at
`docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/01-proposals/linux-expert.md`.

**Headline:** Cautious YAE on NixOS, hard NAY on the user's literal "USB carries
configuration.nix, node imports at boot" model — that pattern does not exist
because `imports` is evaluation-time, not boot-time. Recommended shape:
**closure is static across all 10 nodes; identity is runtime** via an
`apply-identity.service` that reads USB and stages an `EnvironmentFile=` +
`LoadCredential=` for k3s and friends. Same contract as today's Debian
`apply-identity.service`, NixOS-flavored.

Key Linux/sysadmin findings to promote to settled knowledge after compaction:

- **NixOS `imports` is evaluation-time.** Build host evaluates the config; at
  that moment the USB is not mounted on the build host. There is no Nix
  language feature for "import this path at runtime on the target machine."
  Common newbie mistake; worth naming loudly to the team. (Source: Discourse
  "What takes evaluation time?" thread.)
- **`raspberry-pi-nix` is archived (2025-03-23, read-only).** Its README still
  flags Pi 5 USB/NVMe boot as non-working. Do not propose depending on it.
- **`nvmd/nixos-raspberrypi` is the live successor flake.** Latest release
  `v1.20260517.0` (six days before this run). Modules `raspberry-pi-5.base`,
  `raspberry-pi-5.page-size-16k`, `raspberry-pi-5.display-vc4`. Cachix:
  `https://nixos-raspberrypi.cachix.org` / key
  `nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=`.
  Three bootloader options; `kernel` (new, generational) recommended for Pi 5
  installer images. Uses Pi vendor kernel fork.
- **Pi 5 NVMe boot under NixOS is plausible but not the documented happy
  path.** Multiple Discourse threads (2026-05) show users piecing it together
  with disko + nixos-anywhere + nixos-raspberrypi. Treat as "single biggest
  unknown" in the proposal — budget Phase 1 explicitly for it.
- **`services.k3s` NixOS module** exposes 44 options including `enable`,
  `role`, `tokenFile`, `serverAddr`, `extraFlags`, `manifests`,
  `environmentFile`, `nodeName`, `nodeIP`, `clusterInit`, `disable`.
  `tokenFile` reads at service-start, can be a runtime path
  (`/run/credentials/...`). This is materially more declarative than
  `INSTALL_K3S_EXEC` curl-pipe-bash.
- **`services.journald.upload`** supports plain HTTP `URL =
  "http://192.168.10.247:19532"` — drops in cleanly against current
  journal-remote on Akasha. mTLS path: `ServerKeyFile`,
  `ServerCertificateFile`, `TrustedCertificateFile` paths set per drop-in.
  Real-world deployer reported `Buffer space is too small to write entry`
  crash when fronting receiver with TLS-terminating proxy; resolution was raw
  TCP. Keep direct receiver.
- **sops-nix decrypts at activation time, not evaluation time.** Decrypted
  secrets land at `/run/secrets`. For an architecture where the closure is
  generic across hosts (recommended), sops-nix is not the right tool for
  per-host secrets — the USB is. Keep sops-nix in reserve for shared
  secrets that change rarely.
- **GHActions ubuntu-latest QEMU aarch64 build cost** for a Pi-class system:
  ~55 min cold cache, ~5–15 min warm (Cachix + nixos-raspberrypi cache).
  Actuated.com benchmark independently corroborated by multiple bloggers.
  Within free-tier budget; visible but tolerable.
- **NixOS 25.11 "Xantusia"** is the current stable channel (released
  2025-11-30, supported through 2026-06-30). 26.05 "Yarara" mid-2026.
  Pin `flake.lock` to 25.11 for now; revisit at 26.05 release.
- **Impermanence (tmpfs root + persistent state)** is a viable v2 follow-on
  but rejected for v1 — k3s agent dir, containerd image store, journald, SSH
  host keys, machine-id all need explicit persistence; getting it wrong
  wedges nodes in subtle ways. Revisit month 6.
- **`requires=` on a `dev-disk-by-label-*.device` unit** is the clean
  failure-mode design for "USB absent → identity not applied → k3s does not
  start." Node remains SSH-reachable for repair. systemd does NOT
  auto-stop dependent units if the device disappears at runtime — that's
  what we want for a flaky USB connector mid-operation.
- **Pi 5 EEPROM `BOOT_ORDER=0xf641` / `PCIE_PROBE=1`** is below NixOS; the
  existing `configure-eeprom.sh` keeps working unmodified. `rpi-eeprom`
  package is available in nixpkgs (verify path; `pkgs.raspberrypi-eeprom`
  or via `nixos-raspberrypi`).
- **Bus factor honesty**: 20–40 hours of solo NixOS ramp-up before fluent
  ops; team should commit to a 4–6 week ramp and document runbooks for
  every routine task. AC-10 sunset (Debian path stays in repo for 12 weeks)
  is the safety valve.

### 2026-05-23T07:00:00Z — Stage 5.1 re-review of iter-1 revision (nixos-identity-usb)

Wrote `docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/iter-1/05-review/linux-expert.md`.

User correction (00b) shifts framing from "execution debt" to
"architectural failure of reflash mechanism." Under that reframing my
Stage 1 YAE-with-correction position is stronger: replacing a
demonstrated-broken mechanism (vs. iterating on it) is the right move.

**New sysadmin findings promoted from this re-review (worth promoting to
settled knowledge after compaction):**

- **k3s native config drop-ins are the clean per-host-divergence
  mechanism**, not a `lib.mkForce` ExecStart wrapper. k3s reads
  `/etc/rancher/k3s/config.yaml` plus `/etc/rancher/k3s/config.yaml.d/*.yaml`
  in alphabetical order. YAML keys: `node-label:`, `node-taint:`,
  `node-name:`, plus everything else. An activation-time service can
  generate `/etc/rancher/k3s/config.yaml.d/00-identity.yaml` from the
  USB-staged `identity.env`. The NixOS k3s module's `services.k3s` config
  options bake into the closure at evaluation time, which is fine for
  cluster-wide settings (server URL, token file path, role) but **cannot**
  vary per-host from runtime data — the drop-in YAML pattern fills that
  gap without touching ExecStart. Source: docs.k3s.io/installation/configuration.
- **`services.k3s.nodeLabel` and `services.k3s.nodeTaint` are
  evaluation-time list options** in nixpkgs release-25.11 k3s module
  (`nixos/modules/services/cluster/rancher/default.nix` lines 503, 509).
  Listed in the module's ExecStart construction at lines 936-937. Useful
  for cluster-uniform labels but not for per-host divergence under the
  one-closure model.
- **`nixos-raspberrypi` Pi 5 module initrd module set** is:
  `nvme` (from `modules/raspberry-pi-5/default.nix:15-17`) plus
  `xhci_pci`, `usbhid`, `usb_storage`, `vc4`, `pcie_brcmstb`,
  `reset-raspberrypi` (from `modules/raspberrypi.nix:35-42`). So
  `fileSystems."/var/lib/hyperion-id".neededForBoot = true` on a USB
  device by label works in stage-1 *given* the modules are loaded —
  but Pi 5 USB enumeration in stage-1 can be 5–10s slow under cold
  boot. The default `x-systemd.device-timeout=15s` is tight; 60s is
  safer. If the mount times out in stage-1 the node drops to
  initramfs rescue, NOT stage-2 with SSH — different failure class
  than apply-identity-service-fails.
- **`boot.initrd.systemd.enable` controls whether stage-1 uses systemd
  or scripted initrd.** NixOS default is scripted; opt-in to systemd
  initrd. Either way `neededForBoot` does the right thing but the
  failure-mode shell differs (initramfs `sh` vs. systemd emergency
  shell).
- **NixOS `fileSystems.<mount>.neededForBoot` definition** lives at
  `nixos/modules/system/boot/stage-1.nix:704-712`. The option's
  description: "If set, this file system will be mounted in the
  initial ramdisk." Path-specific defaults (`/`, `/nix`, `/nix/store`,
  `/var`, `/var/log`, `/var/lib`, `/etc`, `/usr`) are always mounted
  in stage-1 regardless of the option.
- **GHA scheduled workflows are best-effort, not guaranteed.** Cron
  triggers can lag hours-to-a-day or skip during GitHub platform
  incidents. For sunset enforcement (or any other date-sensitive
  trigger), back the workflow with a git-committed file the workflow
  reads from, so the operator's routine `git pull` surfaces the same
  information.
- **SSH-session-based intervention-time instrumentation pattern**: journal-remote
  already collects `sshd[*]: Accepted publickey for owner from ...`
  lines from every node. A periodic timer on Akasha can grep these,
  sum durations, and auto-write to `intervention-log-auto.md` to
  backstop the operator's manual log. Useful for the muddy-failure
  gate in the NixOS pipeline.

**Outstanding gaps from Stage 1 that the revision didn't address (carried
forward to Phase 1):**

- `services.openssh.hostKeys = lib.mkForce [...]` to suppress first-boot
  key regeneration when the node has USB-supplied persistent keys.
- Identity USB schema-version refusal contract (what does the node do
  with schema 1 vs schema 2 vs schema 3?).
- `users.users.owner` + `services.openssh.passwordAuthentication = false`
  in `hyperion-base.nix` — routine but unspecified.

Vote-shape: trending YAE with conditions. Would flip to NAY if §G.3
wrapper-ExecStart stays as-written without commitment to drop-in pattern,
or if §C.1 muddy-failure threshold gets watered down in Stage 6.

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
- **NixOS Wiki — NixOS on ARM / Raspberry Pi 5** — current community
  recommendation for Pi 5 (nvmd/nixos-raspberrypi); Cachix URL+key.
  https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_5 — accessed
  2026-05-23 — confidence: community wiki / official
- **GitHub — nix-community/raspberry-pi-nix (archived)** — Pi 5
  USB/NVMe boot listed as non-working; project archived 2025-03-23.
  https://github.com/nix-community/raspberry-pi-nix — accessed
  2026-05-23 — confidence: official upstream (archived)
- **GitHub — nvmd/nixos-raspberrypi** — live Pi 5 flake; latest tag
  v1.20260517.0 (six days before this run); Cachix details; bootloader
  module options.
  https://github.com/nvmd/nixos-raspberrypi — accessed 2026-05-23 —
  confidence: community active
- **NixOS Discourse — Pi 5 Desktop on NVME with LUKS** — community
  thread confirming disko + nixos-anywhere on Pi 5 NVMe is being
  done; resources scattered.
  https://discourse.nixos.org/t/raspberry-pi-5-desktop-on-nvme-with-luks/60110
  — accessed 2026-05-23 — confidence: community
- **NixOS Discourse — Flake: NixOS on Raspberry Pi 5 (May 2026)** —
  current state of community-maintained flake options.
  https://discourse.nixos.org/t/flake-nixos-on-raspberry-pi-5/77589 —
  accessed 2026-05-23 — confidence: community
- **services.k3s module options (MyNixOS)** — 44 options enumerated;
  agent vs server role, tokenFile path semantics.
  https://mynixos.com/options/services.k3s — accessed 2026-05-23 —
  confidence: derived from upstream nixpkgs
- **NixOS K3s wiki** — config patterns, extraFlags for disable, token
  change gotchas (issue #308201).
  https://nixos.wiki/wiki/K3s — accessed 2026-05-23 — confidence:
  community wiki
- **NixOS Discourse — centralized logging journal-remote/journal-upload**
  — services.journald.upload settings.Upload interface; HTTP and TLS
  paths; TLS-via-proxy bug.
  https://discourse.nixos.org/t/setting-up-centralized-logging-with-journal-remote-and-journal-upload/49588
  — accessed 2026-05-23 — confidence: community
- **GitHub — Mic92/sops-nix** — activation-time decryption,
  `/run/secrets` path, evaluation-vs-activation timing.
  https://github.com/Mic92/sops-nix — accessed 2026-05-23 —
  confidence: community / well-maintained
- **NixOS Wiki — Impermanence** — tmpfs-root pattern, what must persist
  (k3s, containerd, machine-id, journal), trade-offs.
  https://wiki.nixos.org/wiki/Impermanence — accessed 2026-05-23 —
  confidence: community wiki / official module
- **NixOS 25.11 release announcement (Xantusia)** — current channel,
  EOL 2026-06-30, 26.05 Yarara next.
  https://nixos.org/blog/announcements/2025/nixos-2511/ — accessed
  2026-05-23 — confidence: official
- **Actuated.com — faster Nix builds with GitHub Actions** —
  ubuntu-latest QEMU aarch64 benchmark (~55 min cold for Pi-class
  build); comparison to native ARM runners.
  https://actuated.com/blog/faster-nix-builds — accessed 2026-05-23
  — confidence: vendor blog (benchmark numbers independent)
- **NixOS Discourse — What takes evaluation time?** — authoritative
  thread on `imports` and what runs at evaluation vs activation vs
  runtime. The basis for refuting the "USB imported at boot" mental
  model.
  https://discourse.nixos.org/t/what-takes-evaluation-time/47692 —
  accessed 2026-05-23 — confidence: community / authoritative
- **Jeff Geerling — Pi 5 NVMe SSD boot** — BOOT_ORDER=0xf641 syntax,
  PCIE_PROBE=1 for non-HAT+ adapters. Already used by current
  `configure-eeprom.sh`.
  https://www.jeffgeerling.com/blog/2023/nvme-ssd-boot-raspberry-pi-5/
  — accessed 2026-05-23 — confidence: vendor-adjacent authority

---

## Archive
