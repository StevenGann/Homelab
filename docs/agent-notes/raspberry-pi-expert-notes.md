---
agent: Raspberry Pi Expert
specialization: Pi 5 hardware, EEPROM, config.txt/cmdline.txt, PoE+/M.2 HATs, NVMe boot, Pi OS
last_compacted_utc: 2026-05-03T23:42:42Z
last_updated_utc:   2026-05-04T00:25:00Z
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
(`0xf641` → loop), and depending on what else is plugged in, it could end up
back on the previous installation's residual MBR if the dd was incomplete, or
appear "not flashed." Source: rpi-eeprom issue #629.

### 2026-05-04T00:25:00Z — PCIe warm-reboot regression (rpi-eeprom #718)

Same `BOOT_ORDER=0xf641`, `BOOT_UART=1`: NVMe is found on cold power-on but
**not on `sudo reboot`** ("PCIe timeout 0x0001e08f" → "Failed to open device:
'nvme'"). Workaround is full power cycle. `bootstrap.sh` line 403/464 issues
`systemctl reboot` after success — exactly the warm-reboot path that triggers
this. Even if dd succeeded, the post-flash warm reboot can land back in the
bootstrap (on whichever USB stick is still inserted) or fall through to loop.

### 2026-05-04T00:25:00Z — `dtparam=nvme` is auto-set when booted from NVMe

Per Pi firmware release notes, the bootloader now "automatically sets
`dtparam=nvme` if booted from nvme." Means Node IMG's explicit
`dtparam=nvme` (in `[pi5]` block of config.txt) is a no-op when it matters
most — when the boot chain is firmware → NVMe. It only helps when the boot
chain is firmware → USB → kernel-then-load-NVMe-driver, which is exactly the
bootstrap scenario. So **the Bootstrap IMG actually needs `dtparam=nvme`
in its own config.txt, not the Node IMG.** Verify whether the Bootstrap IMG
inherits this from Pi OS Lite defaults (it might — Pi OS Trixie auto-loads the
NVMe driver on PCIe enumeration).

### 2026-05-04T00:25:00Z — `BOOT_UART=1` semantics

Per firmware-2712 release notes: defaults to 1 in current firmware, "gives
useful diagnostics for device-tree loading with minimal overhead." Bootloader
output on GPIO 14/15. Baud is `UART_BAUD` (default 115200). `enable_uart=1` is
the *kernel*-side equivalent for after the kernel takes over. For full
boot-to-runtime UART visibility we want **both** `BOOT_UART=1` (EEPROM) and
`enable_uart=1` (config.txt).

### 2026-05-04T00:25:00Z — `partprobe` + `udevadm settle` after `dd` on a busy NVMe

`bootstrap.sh:411–414` does `dd ... ; sync ; partprobe ; udevadm settle
--timeout=10`. On Pi 5, after re-imaging the NVMe under a running kernel that
already had `nvme0n1p1`/`p2` enumerated from the *old* image, the kernel's
existing partition table may not be re-read if any block is held open (e.g. by
the kernel's pagecache). `partprobe` returns success but the new partition
nodes can be stale. Symptom: line 421 `mount "${NVME}p1" "$TMPBOOT"` mounts
the *old* p1 (which still exists if the new image's p1 is in the same offset),
the script writes its version-stamp deletion to the wrong fs, and the
post-reboot NVMe boots the old image because cmdline.txt and node-img.ver
were never actually modified on the *new* p1. **High-information-gain test:**
add `blkdiscard` or `wipefs -a $NVME` before `dd` and inspect `lsblk -f
/dev/nvme0n1` immediately after `udevadm settle`.

### 2026-05-04T00:25:00Z — exFAT + power-loss on identity USB

`flash-identity-usb.sh` uses exFAT (line 84). exFAT does not journal. The
bootstrap script writes `version.tmp` then renames to `version` (line 357–
359), which is mostly safe — but writes to `bootstrap.log` on the same exFAT
fs are not safe across power cuts. If the user pulled the USB *during* the
flash (which they shouldn't, but the LED was rapid-blinking when they
unplugged), exFAT could be corrupt enough to make the cache directory
unreadable on next attempt. Less likely the root cause, more a footgun.

### 2026-05-04T00:25:00Z — `find -delete` vs the active image inside `dd`

`bootstrap.sh:353` runs `find "$CACHE_DIR" -name '*.img' ! -name "..."
-delete` *before* the dd at line 411. That ordering is fine. But: if the
user has multiple `*.img` files in the cache from prior runs, the loop at
line 373 picks the first `*.img` glob match — order is **filesystem-defined,
not lexicographic on exFAT**. Could pick a stale image. Combined with the
USB_VER stamp being read from `version` (not from inside the .img), a stale
.img with a current `version` file flashes the wrong content. Worth checking
the cache dir contents post-failure.

### 2026-05-04T00:25:00Z — bootstrap.service starts before status server is reachable

`bootstrap.service` is `Type=oneshot` `After=network-online.target`. The
script's `_start_status_server` runs *after* a long pre-flight (LED init,
EEPROM check, USB wait up to 30s). The 8080 server only comes up at line 232.
If the user `curl`'d the HTTP endpoint and got it working, then later got 404,
the most likely sequence is: server came up → script progressed → `cleanup()`
EXIT trap killed the python httpd → user's next curl gets ECONNREFUSED, which
some clients render as "404." Bootstrap script either succeeded-then-rebooted
(cleanup runs on `systemctl reboot` exit), errored-then-`die`d (cleanup runs
in the trap), or hit `exec /bin/bash` after MAX_BOOT_ATTEMPTS (cleanup also
runs because exec replaces the process). All three look identical from the
outside: HTTP went away. **The 404 itself is not diagnostic.** Need the last
JSON body before 404, or the contents of `bootstrap.log` on identity USB.

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
- **rpi-eeprom #629 — Rpi 5 NVMe boots only if USB-MSD is there.** Pi 5 NVMe
  enumeration sometimes requires a USB-MSD device on a port; closed
  not-planned. Directly relevant to nvme-not-flashing.
  https://github.com/raspberrypi/rpi-eeprom/issues/629 — accessed
  2026-05-04 — confidence: community (vendor tracker, vendor-acknowledged)
- **rpi-eeprom #718 — pi5 second PCIe boot fails.** `systemctl reboot` after
  successful boot fails to re-enumerate NVMe; cold power-cycle works. Direct
  match for the script's post-flash `systemctl reboot`.
  https://github.com/raspberrypi/rpi-eeprom/issues/718 — accessed
  2026-05-04 — confidence: community (vendor tracker, open)
- **firmware-2712 release notes** — `BOOT_UART`, `UART_BAUD`,
  auto-`dtparam=nvme`-when-NVMe-booted, `PCIE_PROBE=1` for non-spec HATs.
  https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2712/release-notes.md
  — accessed 2026-05-04 — confidence: official (vendor source, primary)
- **Dzombak — Remote logging for Pi debugging (rsyslog forwarding pattern).**
  Rationale and tmpfs-spool advice for runtime log shipping. Does NOT cover
  pre-network-up phase. https://www.dzombak.com/blog/2023/12/remote-logging-for-easier-raspberry-pi-debugging/
  — accessed 2026-05-04 — confidence: community (practitioner blog)

---

## Archive
