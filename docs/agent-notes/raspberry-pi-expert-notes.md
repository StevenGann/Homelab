---
agent: Raspberry Pi Expert
specialization: Pi 5 hardware, EEPROM, config.txt/cmdline.txt, PoE+/M.2 HATs, NVMe boot, Pi OS
last_compacted_utc: 2026-05-21T15:10:00Z
last_updated_utc:   2026-05-21T15:10:00Z
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

---

## Active observations

<!-- Append new items at the bottom: `### YYYY-MM-DDTHH:MM:SSZ — title` -->

### 2026-05-04T00:25:00Z — USB-MSD-presence quirk on Pi 5 NVMe boot (rpi-eeprom #629)

Some Pi 5 + NVMe-HAT combinations exhibit "NVMe only enumerates when a USB
mass-storage device is also attached" (`nvme: error 10` otherwise). Closed by
the Pi team as "not planned." Implication for nvme-not-flashing: if the user
unplugs the bootstrap USB *before* the post-flash reboot, on affected nodes the
EEPROM bootloader's NVMe stage may fail to enumerate the freshly-flashed drive
on the next cold boot — Pi falls through to the next entry in BOOT_ORDER
(`0xf641` → loop). Source: rpi-eeprom issue #629.

### 2026-05-04T00:25:00Z — PCIe warm-reboot regression (rpi-eeprom #718)

Same `BOOT_ORDER=0xf641`, `BOOT_UART=1`: NVMe is found on cold power-on but
**not on `sudo reboot`** ("PCIe timeout 0x0001e08f" → "Failed to open device:
'nvme'"). Workaround is full power cycle. `bootstrap.sh` line 403/464 issues
`systemctl reboot` after success — exactly the warm-reboot path that triggers
this.

### 2026-05-04T00:25:00Z — `dtparam=nvme` auto-set when booted from NVMe

Per Pi firmware release notes, the bootloader auto-sets `dtparam=nvme` when
booting from nvme. So **the Bootstrap IMG actually needs `dtparam=nvme`
in its own config.txt, not the Node IMG.**

### 2026-05-04T00:25:00Z — `BOOT_UART=1` + `enable_uart=1` for end-to-end UART

For full boot-to-runtime UART visibility set **both** `BOOT_UART=1` (EEPROM) and
`enable_uart=1` (config.txt).

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

---

## Archive
