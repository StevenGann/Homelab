---
agent: Raspberry Pi Expert
specialization: Pi 5 hardware, EEPROM, config.txt/cmdline.txt, PoE+/M.2 HATs, NVMe boot, Pi OS
last_compacted_utc: 2026-05-21T15:10:00Z
last_updated_utc:   2026-05-23T05:30:00Z
---

# Raspberry Pi Expert — Notes

> **Compaction protocol.** Before doing any substantive work, check `last_compacted_utc`
> in the frontmatter above. If it is more than 24 hours older than current UTC,
> compact this file first (merge duplicates, promote stable findings to "Settled
> knowledge", verify claims against current repo state, drop noise), then update
> `last_compacted_utc`. See `TEAM.md` for the full protocol.

**Scope.** Pi-5-specific hardware, firmware, and boot-path knowledge. Anything that
behaves differently on Pi than on a generic Linux box.

---

## Settled knowledge

### Hyperion hardware baseline

- Pi 5 + PoE+ HAT + M.2 HAT + NVMe SSD (256 GB at `/dev/nvme0n1`).
- 8 GB RAM standard; **two of the ten nodes are 4 GB** — keep workload sizing
  conservative when scheduling assumes uniform memory.
- All ten nodes are at `192.168.10.101–.110`, static DHCP via UCG. The MetalLB
  pool occupies `.10–.99` (verified in `Hyperion/k8s/infrastructure/metallb/ipaddresspool.yaml`).

### Boot order — `0xf641`

Nibbles read **right-to-left**:

| Nibble | Mode | Meaning |
|--------|------|---------|
| `1` | 1st | SD card (Bootstrap IMG) |
| `4` | 2nd | USB mass storage (Bootstrap IMG, alternate medium) |
| `6` | 3rd | NVMe (production OS) |
| `f` | 4th | Loop |

Stored in **SPI flash** — surviving NVMe re-imaging is the entire point. Either SD
**or** USB works as bootstrap medium because nibble 4 was added specifically to
allow USB-stick bootstrap.

### Pi 5 `config.txt` essentials

Inside the `[pi5]` block:

```ini
kernel=kernel_2712.img    # BCM2712 kernel — Pi 5 specific
auto_initramfs=1          # Required on Trixie
dtparam=pciex1_gen=3      # Gen 3 PCIe — overclock from spec Gen 2
dtparam=nvme              # Belt-and-suspenders for NVMe boot on some EEPROM versions
```

`dtparam=pciex1_gen=3` is an **overclock**. Spec is Gen 2. Some NVMe drives are
unstable at Gen 3 — verify on a single node before rolling out new SSD models.

### EEPROM update

`sudo rpi-eeprom-update -a && sudo reboot` — required to standardize firmware
across nodes purchased in different batches. Different EEPROM versions handle
NVMe boot differently.

`BOOT_UART=1` enables bootloader output on GPIO 14/15 at 115200 baud. Useful
during commissioning; disable once the cluster is stable.

### k3s configuration on Hyperion

- Server runs in Docker on Monolith (`rancher/k3s:v1.35.3-k3s1`) per
  `Monolith/k3s-control-plane/docker-compose.yml`.
- Agents installed on Pi nodes via `Hyperion/ansible/k3s-agent.yml` with the
  **stock get.k3s.io install**, **no `INSTALL_K3S_EXEC` flags** — meaning
  the bundled Traefik and ServiceLB defaults *are not currently disabled*.
- MetalLB is committed to `Hyperion/k8s/infrastructure/metallb/` so it's
  intended to replace ServiceLB, but the k3s install line doesn't yet pass
  `--disable=servicelb`. **This is a latent conflict** — see Active observations.

### Pi 5 NVMe boot — recurrent failure modes (promoted from 2026-05-04 obs)

These four observations have been stable across multiple debug pipeline cycles
and stand independent of OS choice. They live in **firmware/silicon**, not OS:

- **USB-MSD-presence quirk (rpi-eeprom #629).** Some Pi 5 + NVMe-HAT combos
  fail NVMe enumeration unless a USB mass-storage device is also attached
  at cold boot. Pi team closed "not planned." Identity USB stick, since it's
  always physically attached, may inadvertently mitigate this — worth
  testing if we ever consider removing it.
- **Warm-reboot regression (rpi-eeprom #718).** Cold boot enumerates NVMe;
  `sudo reboot` / `systemctl reboot` does not, fails with
  `PCIe timeout 0x0001e08f` → `Failed to open device: 'nvme'`. Workaround:
  full power cycle. **Any reflash/restart workflow must avoid warm reboot
  as the last step.**
- **`dtparam=nvme` auto-set on NVMe boot.** Pi firmware auto-applies it when
  booting *from* NVMe — but bootstrap medium (SD or USB) still needs it
  explicitly in its own `config.txt` for first-NVMe-enumeration. Same logic
  applies to any installer-SD-based imaging flow.
- **PCIE_PROBE=1 is opt-in and was added 2023-11-20 to firmware-2712.**
  Older EEPROMs silently ignore it; ordering is `rpi-eeprom-update -a` then
  apply `PCIE_PROBE=1`. EEPROM management is a separate operator workflow
  from OS configuration regardless of OS choice.

### PoE+ HAT power-budgeting

Pi 5 + PoE+ HAT delivers power via the 40-pin header. Pi-OS power-detection
clips USB output to **600 mA** unless `usb_max_current_enable=1` is in
`config.txt`, which allows passthrough up to 1.6 A. **Required for any
bus-powered USB device (including identity sticks under heavy first-boot
load) on PoE+ HAT-powered Pis.** This applies to any OS — the limiting
behavior is firmware-enforced based on the config.txt directive.

### NixOS on Pi 5 — current state (verified 2026-05-23)

- **Official upstream nixpkgs:** "Not officially supported." (NixOS wiki,
  Raspberry Pi 5 page.) Community projects only.
- **`nix-community/raspberry-pi-nix`:** **ARCHIVED 2025-03-23.** README's
  "What's not working" lists Pi 5 NVMe boot explicitly. Do not use.
- **`nvmd/nixos-raspberrypi`:** Active successor. 543+ stars, 500+ commits,
  11 releases. Supports `kernelboot` (legacy), `uboot`, and `kernel`
  (generational, recommended for Pi 5) bootloaders. Integrates with
  `nixos-anywhere` + `disko`. **`kexec` not supported** on Pi 5.
- **Pi 5 NVMe boot under nvmd/nixos-raspberrypi:** State is **unknown but
  improving**. Closed issue #117 ("Boot from NVMe drive: Firmware error",
  closed Dec 2025 without documented fix). Open issue #159 ("Installing to
  m.2 disk", opened Mar 2026, no resolution as of Apr 2026). Discourse
  threads report mixed results.
- **Image format:** `nixos-generators` with `format = "sd-aarch64-installer"`.
  Cross-compilable from x86 via QEMU binfmt — viable on `ubuntu-latest`
  GitHub runners.
- **config.txt generation:** `hardware.raspberry-pi.config` Nix attribute
  set autogenerates `/boot/firmware/config.txt`. Pi-5-specific block
  must be declared explicitly (no auto-defaults documented for
  `kernel_2712.img`, `auto_initramfs`, `dtparam=nvme`,
  `dtparam=pciex1_gen=3`, `usb_max_current_enable=1`, `enable_uart=1`).
- **EEPROM:** No NixOS module manages it. `rpi-eeprom-update` is in
  nixpkgs but should remain a separate operator workflow per the standing
  H4 thread guidance.

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

> **Note (2026-05-23 compaction):** The four hardware-firmware obs items from
> 2026-05-04 (rpi-eeprom #629 USB-MSD presence; rpi-eeprom #718 warm-reboot
> regression; `dtparam=nvme` auto-set behavior; `BOOT_UART=1` + `enable_uart=1`)
> were promoted to Settled Knowledge above. The Debian-bootstrap.sh-specific
> obs (partprobe race, exFAT no-journal, find-delete glob order, status-server
> lifecycle) are preserved below — they are bootstrap-script-specific and may
> become moot if the NixOS pivot in pipeline-run `20260523T050133Z` proceeds.

### 2026-05-04T00:25:00Z — `partprobe` + `udevadm settle` after `dd` on busy NVMe

After dd, kernel may not re-read partition tables if any block is held open. Add
`blkdiscard` or `wipefs -a $NVME` before `dd` and verify `lsblk -f /dev/nvme0n1`
immediately after `udevadm settle`.

### 2026-05-04T00:25:00Z — exFAT identity USB has no journal

`flash-identity-usb.sh` uses exFAT (line 84). exFAT does not journal. Writes
during flash (incl. `bootstrap.log`) are not safe across power cuts.

### 2026-05-04T00:25:00Z — `find -delete` glob order on exFAT is non-deterministic

`bootstrap.sh:353` glob order is filesystem-defined on exFAT, not lexicographic.
Stale `.img` could be picked.

### 2026-05-04T00:25:00Z — bootstrap.service status-server lifecycle

`Type=oneshot` + `cleanup()` EXIT trap kills the python 8080 server on any exit
(success-and-reboot, error-and-die, or `exec /bin/bash` after MAX_BOOT_ATTEMPTS).
All three look identical from the outside — HTTP 404/refused is **not diagnostic**
on its own; need the last JSON body or `bootstrap.log` on identity USB.

### 2026-05-17T18:45:00Z — Stage 1 dev-heimdall-tech-stack — Pi-as-consumer angle

Working through how the Heimdall edge stack interacts with Hyperion. Key facts
relevant to the proposal:

- k3s agent install in `ansible/k3s-agent.yml` is plain `curl get.k3s.io | sh`
  with no `INSTALL_K3S_EXEC` — Traefik and ServiceLB are both still enabled on
  the agents by default. MetalLB will only work cleanly once ServiceLB is
  disabled (otherwise both fight for the same `Service type=LoadBalancer`
  fulfillment).
- MetalLB `homelab-pool` is `192.168.10.10-99`, L2 advertisement
  (single-VLAN ARP). Heimdall sitting at any `192.168.10.x` outside that pool
  is fine; if Heimdall takes `192.168.10.2` (next to UCG) the optics are clean.
- Pi-hosted *Minecraft-on-k8s* and similar UDP/long-lived TCP workloads are
  the main Heimdall→Pi traffic class to think about. ARM64 image coverage
  for the candidate edge stack matters if anything moves to a Pi later.
- All ARM64-capable container images: Caddy, Traefik, AdGuard Home, Pi-hole,
  CoreDNS, HAProxy, NGINX, Dockge — already verified available on Docker Hub /
  ghcr for arm64 in past lookups; will re-verify in Stage 1 web search.

### 2026-05-21T15:10:00Z — Stage 1 dev-hyperion-flashing-to-heimdall — back in for Hyperion

Sidelined during Heimdall pipeline (x86, no Pi value-add). Back for Hyperion work.

Re-verified against current bootstrap.sh (430+ lines):
- `MONOLITH_BASE` is at **line 32**, not as documented in earlier notes — single
  point-of-edit for image-server cutover.
- `:8080` status server is `Python3` baked into `/tmp/bootstrap-httpd.py` —
  starts at line 174, served via `STATUS_FILE` JSON + `LOG_FILE` tail. Lifecycle
  fix (2026-05-04 pipeline): status server is now started **before** the
  MAX_BOOT_ATTEMPTS gate so attempt 4+ exposes `"status":"exhausted_attempts"`
  instead of connection-refused.
- Bootstrap IMG has `resolv-conf = "copy-host"` only — **no LAN DNS baked in.**
  Pi gets DNS via DHCP. Today UCG serves DHCP; UCG hands out itself (`.1`) as
  DNS unless changed. UCG knows nothing about `.lab`. Therefore using
  `images.lab` / `journal.lab` hostnames in bootstrap.sh **fails until DHCP
  option 6 points at Heimdall** — IP-only for early boot is the safe default.
- `:8080/log` route returns 404 until step 1 (HYPERION-ID USB mount) completes,
  because `LOG_FILE` lives on the identity USB. JSON status on `/` works from
  the very first `set_status "starting"` call (line 267).

`set_status` calls and the phase tag exposed at `:8080`:
| step | phase | status |
|------|-------|--------|
| 0 | starting | working |
| 0 | exhausted_attempts | error (post-MAX_BOOT_ATTEMPTS) |
| 0 | eeprom_check | working |
| 1 | usb_wait | working |
| 2 | network_wait | working |
| 2 | network_check | working |
| 3 | downloading | downloading |
| 3 | verifying | working |
| 4 | usb_verify | working |
| 5 | version_check | working |
| 6 | flashing | flashing |
| 7 | repartitioning | working |
| 8 | done | done |
| any | error | error (via die()) |

That phase string IS the H1–H6 router. The realtime tool doesn't need to
invent classifications — it just needs to render phase+status+last-log-line.

### 2026-05-21T15:10:00Z — Pi 5 NVMe quirks re-verified (rpi-eeprom #629/#718/#816)

- **#629** (USB-MSD-presence quirk) — confirmed still open per March-2026 forum
  reports. Affected nodes need a USB-MSD device attached for NVMe to enumerate
  on cold boot. Bootstrap medium (SD or USB stick) being inserted satisfies
  this; pulling all USB devices after a successful flash and cold-booting is
  the failure case.
- **#718** (warm-reboot PCIe timeout) — confirmed still open, June-2025 reports
  match the same `PCIe timeout 0x0001e08f` → `Failed to open device: 'nvme'`
  signature. Workaround = power-cycle, not soft-reboot.
  **bootstrap.sh:472 and :545 both `systemctl reboot`** — exactly the warm-reboot
  trigger. Affected nodes will Pi-reboot from SD → bootstrap re-runs → sees
  NVMe is current → reboots into NVMe — and on that second reboot, NVMe may
  fail to enumerate. Visible in the realtime tool as: bootstrap cycle 1 ends
  in `phase=done`, then bootstrap cycle 2 starts (SD card boots again) but
  shows `NVMe version : 0` again (because NVMe didn't enumerate so the version
  read at line 457 returns 0).
- **#816 (new, March-2026)** — Pi 5 + WD SN850X via Argon NEO5 fails to
  enumerate NVMe at early boot. **Possible third failure mode for the
  not-flashing bug.** Worth checking SSD model on affected nodes.

### 2026-05-21T15:10:00Z — Two-reboot success signature

After a successful flash, the operator should see (assuming bootstrap medium
left in):
1. Cycle 1: phase=starting → ... → phase=flashing → phase=repartitioning → phase=done. systemctl reboot.
2. Cycle 2: phase=starting → ... → phase=version_check shows USB_VER==NVME_VER → phase=done immediately. systemctl reboot.
3. Bootstrap medium then removed → next cold boot lands on NVMe (Node IMG running, `:8080` is gone, journal-upload to journal-remote takes over).

If cycle 2 shows NVME_VER=0 again, that's H4 (NVMe didn't re-enumerate on warm
reboot). The realtime tool should explicitly show NVMe-version readback so
that signature is visible.

### 2026-05-21T15:10:00Z — Proposal submitted

Submitted `01-proposals/raspberry-pi-expert.md`. Top-line: Heimdall fronts
MetalLB VIPs (not replaces them); k3s-agent install must add
`--disable=servicelb` to stop ServiceLB fighting MetalLB; control plane gets
`--disable=traefik` and Traefik is redeployed via Flux; Pi DNS records are a
flat zone file in repo; Minecraft uses MetalLB `allow-shared-ip` for TCP+UDP
on one VIP, RCON stays internal-only, PROXY-protocol v2 from Heimdall preserves
original client IP for TCP. Caddy-l4 flagged as "experimental and requires
xcaddy build" so my preference for L4 is HAProxy or Traefik IngressRouteTCP/UDP
over Caddy-l4.

New verified facts:
- MetalLB `allow-shared-ip` annotation pattern for TCP+UDP-on-same-VIP is
  official (metallb.universe.tf/usage/).
- k3s `coredns-custom` ConfigMap is the documented way to inject DNS forwarding
  zones into the cluster CoreDNS without a fork.
- HAProxy has an official "passive FTP" tutorial covering port-range +
  stick-table session persistence — FTP-passive isn't hand-wavable but is
  solved.
- Caddy-l4 explicitly self-describes as "experimental" and "JSON-only,
  no Caddyfile yet" — operational red flag for KISS/reconstructability.

### 2026-05-23T05:30:00Z — Stage 1 dev-nixos-identity-usb — NixOS pivot proposal

Submitted `01-proposals/raspberry-pi-expert.md` for pipeline-run
`20260523T050133Z-dev-nixos-identity-usb`. Headline: pivot is viable at the
silicon/firmware boundary but **bet-the-cluster gated on Phase 0 single-node
NVMe-boot validation under `nvmd/nixos-raspberrypi`**. Three of six current
debug-pipeline hypothesis classes (H2/H3/H6) become architecturally
impossible; two (H1/H5) shift to new code paths; one (H4: EEPROM /
PCIE_PROBE / rpi-eeprom #629+#718) is unchanged because that's firmware,
not OS. EEPROM stays external via `configure-eeprom.sh`; HW-replacement
stays at 3 operator steps (USB swap, DHCP update, power-on) with a
one-time installer-SD reflash equivalent to today's bootstrap insertion.

New verified facts (with implications for Pi work generally, not just this
pipeline):
- **`nix-community/raspberry-pi-nix` is archived since 2025-03-23.** Its
  README's "What's not working" lists Pi 5 NVMe boot. The community has
  consolidated on `nvmd/nixos-raspberrypi` as the active Pi 5 path.
- **`nvmd/nixos-raspberrypi` recommends `bootloader = "kernel"` for Pi 5**
  (its "kernel" generational bootloader supports multiple NixOS
  generations; default for Pi 5 sd-image/installer per upstream README).
  `kexec` is explicitly not supported on Pi 5.
- **NixOS Pi 5 NVMe boot status is mixed.** Issue #117 closed without
  documented fix (Dec 2025); issue #159 open with no resolution (Mar 2026);
  Discourse reports describe the universal aarch64 installer not
  recognizing NVMe and Pi-5-specific sd-image not booting with LUKS.
- **firmware-2712 latest release re-verified today: 2026-05-22.** The
  PCIE_PROBE introduction-date of 2023-11-20 still holds; it remains
  opt-in only. Pi 5 EEPROM update flow stays as documented in the standing
  H4 thread.
- **`usb_max_current_enable=1` is required on PoE+ HAT regardless of OS.**
  Pi-OS clips USB to 600 mA otherwise; identity USB enumeration under load
  may be affected. Need to add this directive to whatever config.txt we
  end up generating, including the current Debian-Packer path (it is
  NOT in `rpi-node.pkr.hcl` today — open todo for any path forward).
- **`disko` is the standard declarative-partitioning Nix module** and
  supports `device = "/dev/nvme0n1"` directly; viable for replacing
  bootstrap.sh's NVMe partitioning logic on the NixOS path.

Cross-pipeline implication (for debug pipeline `20260504T000719Z`): even
if the NixOS pivot is accepted, the Pi 5 NVMe warm-reboot regression
(#718) and USB-MSD-presence quirk (#629) **persist**. Any future bring-up
flow (NixOS or Debian) should operationally avoid `reboot` as the last
step before relying on NVMe enumeration; prefer `poweroff` followed by
external power cycle.

---

## Sources

- **Raspberry Pi 5 product brief** — official Pi 5 documentation hub.
  https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html —
  accessed 2026-05-03 — confidence: official
- **Raspberry Pi bootloader configuration** — `BOOT_ORDER` nibble reference.
  https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration —
  accessed 2026-05-03 — confidence: official
- **`config.txt` reference** — all directives.
  https://www.raspberrypi.com/documentation/computers/config_txt.html —
  accessed 2026-05-03 — confidence: official
- **Pi 5 + RP1 kexec issue** — context for why netboot/initramfs approach was
  abandoned. https://github.com/raspberrypi/linux/issues/6465 — accessed
  2026-05-03 — confidence: community (upstream tracker)
- **rpi-eeprom #629 — Rpi 5 NVMe boots only if USB-MSD is there.**
  https://github.com/raspberrypi/rpi-eeprom/issues/629 — accessed
  2026-05-04 — confidence: community (vendor tracker, vendor-acknowledged)
- **rpi-eeprom #718 — pi5 second PCIe boot fails.**
  https://github.com/raspberrypi/rpi-eeprom/issues/718 — accessed
  2026-05-04 — confidence: community (vendor tracker, open)
- **firmware-2712 release notes.**
  https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2712/release-notes.md
  — accessed 2026-05-04 — confidence: official (vendor source, primary)
- **Dzombak — Remote logging for Pi debugging.**
  https://www.dzombak.com/blog/2023/12/remote-logging-for-easier-raspberry-pi-debugging/
  — accessed 2026-05-04 — confidence: community (practitioner blog)
- **rpi-eeprom #816 — Pi 5 fails to boot WD SN850X via Argon NEO5 (NVMe not
  enumerated during early boot).**
  https://github.com/raspberrypi/rpi-eeprom/issues/816 —
  accessed 2026-05-21 — confidence: community (vendor tracker, open as of Mar 2026)
- **Forum: BOOT_ORDER right-to-left nibble priority** — confirms `0xf641`
  reads SD (1) → USB-MSD (4) → NVMe (6) → loop (f).
  https://forums.raspberrypi.com/viewtopic.php?t=366106 — accessed 2026-05-21
  — confidence: community (forum, vendor-staff-confirmed)
- **firmware-2712 release notes (re-verified).**
  https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2712/release-notes.md
  — re-accessed 2026-05-23 — latest release 2026-05-22 — confidence: official.
  Confirms PCIE_PROBE introduced 2023-11-20 (opt-in); 2024-05-13 added
  preliminary PCIe switch support; 2024-01-24 WD Blue SN550 workaround;
  2025-10-08 4K native sector NVMe support.
- **NixOS Wiki — NixOS on ARM / Raspberry Pi 5.**
  https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_5 —
  accessed 2026-05-23 — confidence: community (wiki). "Not officially
  supported"; UEFI vs vendor-firmware routes; `dtoverlay=vc4-kms-v3d-pi5`.
- **nvmd/nixos-raspberrypi README.**
  https://github.com/nvmd/nixos-raspberrypi — accessed 2026-05-23 —
  confidence: community (active flake, 500+ commits). Three bootloaders;
  "kernel" generational recommended for Pi 5; `kexec` unsupported.
- **nix-community/raspberry-pi-nix README (archived).**
  https://github.com/nix-community/raspberry-pi-nix — accessed 2026-05-23 —
  confidence: official-but-archived 2025-03-23. Pi 5 NVMe explicitly listed
  under "What's not working."
- **nvmd/nixos-raspberrypi issue #117 — Boot from NVMe drive: Firmware error.**
  Closed Dec 2025 without documented fix — confidence: community single
  user report (tobiasBora).
- **nvmd/nixos-raspberrypi issue #159 — Installing to m.2 disk.**
  Open since 2026-03-14 — no resolution — confidence: community.
- **NixOS Discourse — Raspberry Pi 5 Desktop on NVMe with LUKS.**
  https://discourse.nixos.org/t/raspberry-pi-5-desktop-on-nvme-with-luks/60110
  — accessed 2026-05-23 — confidence: community.
- **Sourcery Zone — Installing NixOS on Raspberry Pi 5 (Sept 2025).**
  https://sourcery.zone/articles/2025/09/installing-nixos-on-raspberry-pi-5/
  — accessed 2026-05-23 — confidence: community (practitioner).
- **Evan Azevedo — How to Install NixOS on Raspberry Pi 5.**
  https://me.evanazevedo.com/posts/nix-rpi5/ — accessed 2026-05-23 —
  uses UEFI path (`rpi5-uefi`), SD-card only, treats NVMe as "theoretical."
  — confidence: community (practitioner).
- **Haseeb Majid — Setup Raspberry Pi Cluster with K3S and NixOS.**
  https://haseebmajid.dev/series/setup-raspberry-pi-cluster-with-k3s-and-nixos/
  — accessed 2026-05-23 — Pi 4 cluster, sops-nix, Colmena, mDNS/avahi
  for hostname-to-IP. — confidence: community (practitioner blog).
- **Pimoroni forum #23719 — PI 5 NVME Base — `dtparam=pciex1_gen=3` issues.**
  https://forums.pimoroni.com/t/pi-5-nvme-base-issues-with-dtparam-pciex1-gen-3/23719
  — accessed 2026-05-23 — confidence: community.
- **Pi forum #312879 — New PoE+ HAT USB current limits.**
  https://forums.raspberrypi.com/viewtopic.php?t=312879 — accessed
  2026-05-23 — confirms `usb_max_current_enable=1` need under PoE+ HAT
  — confidence: community.
- **Waveshare PoE HAT (H) wiki.**
  https://www.waveshare.com/wiki/PoE_HAT_(H) — accessed 2026-05-23 —
  600 mA USB clip behavior; vendor confirmation — confidence: vendor.
- **disko quickstart.**
  https://github.com/nix-community/disko/blob/master/docs/quickstart.md —
  accessed 2026-05-23 — declarative partitioning; takes `/dev/nvme0n1` —
  confidence: official.
- **NixOS k3s wiki page.**
  https://nixos.wiki/wiki/K3s — accessed 2026-05-23 — `services.k3s.*`
  module is the standard NixOS way to deploy k3s; supports server and
  agent roles, tokenFile for sops integration — confidence: community
  (wiki, but cross-referenced with NixOS Discourse).

---

## Stage 5.1 Re-review findings (2026-05-23, dev-nixos-identity-usb iter-1)

### `nvmd/nixos-raspberrypi` config.txt module API surface — verified today

Confirmed against `modules/{configtxt-config.nix, configtxt.nix, raspberry-pi-5/default.nix, raspberrypi.nix}@develop` at 2026-05-23.

- **Top-level option path:** `hardware.raspberry-pi.config` (defined in `configtxt-config.nix`).
- **Shape:** `attrsOf (submodule raspberry-pi-config-options)` where the attr-name is a config.txt section filter (`all`, `cm4`, `cm5`, `pi5`, ...) and each section has three sub-attrs:
  - `options` → renders to `key=value` lines
  - `base-dt-params` → renders to `dtparam=key=value` lines (value may be omitted for single-token directives like `dtparam=nvme`)
  - `dt-overlays` → renders to `dtoverlay=overlay`/`dtparam=key=value`/`dtoverlay=` blocks
- **Each terminal value:** `{ enable = bool; value = int|str|bool (nullable for base-dt-params); }`
- **Escape hatch:** `hardware.raspberry-pi.config-options.extra-config = "<verbatim text>";` — appended to config.txt raw, bypasses the typed renderer. (Actually `cfg.extra-config` per line 219 of `configtxt-config.nix`; the path is `hardware.raspberry-pi.extra-config`. TODO: verify.)
- **Defaults set by the flake:**
  - `raspberrypi.nix` (all RPi boards): `all.options.{arm_64bit, enable_uart, avoid_warnings}`
  - `configtxt.nix` (all RPi boards): `all.options.{camera_auto_detect, display_auto_detect, max_framebuffers, disable_fw_kms_setup, disable_overscan, arm_boost}` + `all.base-dt-params.audio` + `all.dt-overlays.vc4-kms-v3d` + `cm4.options.otg_mode` + `cm5.dt-overlays.dwc2`
  - **No `pi5` section is defined by default.** The Phase 1 module must create one.
- **`auto_initramfs=1` is commented out** in `configtxt.nix:35-38`. Operator must add explicitly under `hardware.raspberry-pi.config.all.options.auto_initramfs = { enable = true; value = 1; }`.

### `nvmd/nixos-raspberrypi` generational bootloader behavior on Pi 5 — verified today

Confirmed against `modules/system/boot/loader/raspberrypi/{default.nix, generational/*.sh, kernelboot-builder.sh}@develop`.

- **Pi 5 default `bootloader` is `kernelboot`** (`modules/raspberry-pi-5/default.nix:15`: `bootloader = lib.mkDefault "kernelboot";`). Operator must override to `"kernel"` (new generational) or `"uboot"` (U-Boot menu).
- **`kernel` mode (generational):** writes per-generation kernel/initrd/cmdline to `/boot/firmware/<generationName>/` subdirs, plus a copy of the "default" generation's kernel to `/boot/firmware/kernel.img` for the EEPROM to read. No boot menu.
- **`kernelboot` mode (legacy):** writes per-generation files to `/boot/firmware/nixos-kernels/<gen>-{kernel,initrd,cmdline.txt}`, plus a copy of "default" to `/boot/firmware/kernel.img`. No boot menu.
- **`uboot` mode:** writes U-Boot to firmware partition, U-Boot reads `extlinux.conf` listing all generations as menu entries. Menu accessible over UART or attached keyboard.
- **Rollback under `kernel`/`kernelboot`** requires either (a) OS boots far enough to `nixos-rebuild --rollback`, (b) boot an installer SD and chroot to fix `kernel.img`, or (c) pull NVMe and edit FAT partition on workstation. UART alone is insufficient under these modes.
- **`kernel=kernel_2712.img` in config.txt conflicts with the bootloader's output filename `kernel.img`.** Setting it would point the EEPROM at a non-existent file. Either omit (let EEPROM auto-resolve `kernel.img` to BCM2712 binary) or override the bootloader to also emit `kernel_2712.img`.

### Initrd modules for stage-1 USB-mount + NVMe boot

Confirmed against `modules/{raspberrypi.nix, raspberry-pi-5/default.nix}@develop`.

- `boot.initrd.availableKernelModules` includes (from `raspberrypi.nix`): `xhci_pci`, `usbhid`, `usb_storage`, `vc4`, `pcie_brcmstb`, `reset-raspberrypi`.
- Pi 5 module adds: `nvme`.
- Both `usb_storage` and `nvme` are `availableKernelModules` (loaded on udev trigger), not `kernelModules` (force-loaded). For `fileSystems."/var/lib/hyperion-id".neededForBoot = true` to work, stage-1's mount logic triggers udev on the label reference which loads `usb_storage`. This should work but has not been empirically verified on Pi 5 cold boot under PoE+ load.
- `x-systemd.device-timeout=15s` in the revision's §G.4 is tighter than the current bootstrap.sh `USB_WAIT=30s`. On cold Pi 5 with PoE+ HAT, USB enumeration can take 5-10 seconds; 15s budget is risky.

### H-class ranking from prior debug pipeline (Phase 0 of dbg-nvme-not-flashing iter-1)

From `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/iter-1/04-revision.md` §E:

| # | Likelihood | Class |
|---|-----------|-------|
| H1 | HIGH | Bootstrap `die`d before `dd` (variants a/b/c) |
| H2 | HIGH | Version-comparison short-circuit |
| H3 | HIGH | `MAX_BOOT_ATTEMPTS` exceeded |
| H4 | MED | Pi 5 EEPROM / rpi-eeprom #629+#718 |
| H5 | MED | Flash succeeded, user misidentified |
| H6 | LOW–MED | dd/partprobe race |

Per user correction (00b): no class has been further narrowed, but the team has been trying fixes and **nothing produces a working node end-to-end**. The pivot eliminates H2 outright (1 class), partially eliminates H5+H6 (2 classes), renames H3 (different operator burden under `bootloader = "kernel"`), shifts H1a to typed failure, and **does not address H1b or H4** (both firmware-level).

If H4 is the actual blocker, Phase 1 will discover that by failing the NVMe-boot warm-reboot validation. That is the load-bearing test in the entire plan under the user correction framing.

### Stage 5.1 new issues raised in `iter-1/05-review/raspberry-pi-expert.md`

- **N-1 (HIGH):** AC-11 names `hardware.raspberry-pi.config` correctly but omits submodule shape + missing `pi5` section + `kernel=kernel_2712.img` conflicts with bootloader output.
- **N-2 (HIGH):** §H AC-3 H3 row's "U-Boot-mediated or operator-via-UART" rollback claim is wrong for `kernel`/`kernelboot` modes (no UART menu exists; recovery requires installer SD).
- **N-3 (MED):** §C.1 muddy-failure metric should explicitly count firmware burns (rpi-eeprom #629/#718, EEPROM update sequencing) toward the 6-hour budget, otherwise the metric measures OS-only cost.
- **N-4 (LOW):** §G.4 device-timeout 15s is tight on Pi 5 cold boot; recommend 45s + empirical measurement.

### Stage 5.1 vote position

Trending YAE with four conditions (see review file). Phase 1's NVMe-boot validation gate is the H1/H2/H3/H6-vs-H4 discriminator under the user correction — that framing should be made explicit in §B-1 / §C.1.

---

## Archive
