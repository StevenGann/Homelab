# Runbook: Diagnosing a Hyperion node that won't flash

When a node boots from the Bootstrap medium but the NVMe is not getting reflashed (or you're not sure whether it's been reflashed), follow this runbook before touching any code.

> **Source.** This runbook is the operationalised output of the `dbg-nvme-not-flashing` debugging pipeline — see `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/FINAL.md` for the full hypothesis ranking, contingent fix plans, and the team's reasoning.

---

## Critical reframe before you begin

**HTTP 404 from `<node>:8080` is NOT diagnostic of failure.** The Bootstrap script's `cleanup()` trap kills the status server on every exit path — successful flash, "NVMe already current → reboot", `die()`, or `exec /bin/bash` after `MAX_BOOT_ATTEMPTS=3`. All four paths look identical from outside.

**Do not interpret "HTTP went away" as "the script failed."** Read the actual JSON status, the `bootstrap.log` on the identity USB, or the journal. The new status route on `:8080/log` (added 2026-05-04) returns the live tail of `bootstrap.log` over HTTP without needing to mount the USB.

---

## Two-USB requirement

Every bootstrap operation requires **TWO separate USB devices**:

1. **Bootstrap medium** — flashed with `rpi-bootstrap.img`. Identical across all nodes; can be moved between nodes during imaging. SD card OR USB stick (both work; EEPROM `BOOT_ORDER=0xf641` tries SD first then USB).
2. **HYPERION-ID identity USB** — per-node, prepared with `flash-identity-usb.sh /dev/sdX hyperion-<name>`. Holds the node's hostname and an image cache. **Each node has its own.**

If only the bootstrap medium is inserted, the script `die`s at line 323 ("No HYPERION-ID USB found after 30 s"). The improved `die()` message (added 2026-05-04) enumerates detected USB devices so you can immediately see what's missing.

---

## Diagnostic experiment sequence

### Experiment 1 — SSH into the running bootstrap node (5–10 min)

The Bootstrap medium runs Pi OS Lite with sshd enabled as `pi:raspberry`. **This is the highest-value diagnostic action available.**

#### Step 0 — find the node IP

```bash
arp -an | grep -i 'b8:27:eb\|d8:3a:dd\|dc:a6:32'    # Pi MAC OUIs
ip neigh | grep REACHABLE
ping -c 1 -W 1 hyperion-alpha.local                 # mDNS, if avahi is up
# or: UCG admin UI → Clients tab → look for "raspberrypi" hostname
```

#### Step 1 — SSH in and inspect

Bootstrap USB still inserted, HTTP `:8080` returning 404:

```bash
ssh pi@<node-ip>          # password: raspberry

sudo systemctl status hyperion-bootstrap.service
sudo journalctl -u hyperion-bootstrap.service --no-pager | tail -200
sudo cat /tmp/bootstrap-status.json 2>/dev/null
sudo cat /boot/bootstrap-attempts 2>/dev/null
sudo blkid -L HYPERION-ID || echo "NO HYPERION-ID USB"
ID=$(sudo blkid -L HYPERION-ID); [ -n "$ID" ] && sudo mkdir -p /mnt/id && sudo mount -o ro $ID /mnt/id
ls -la /mnt/id/ /mnt/id/node-image/ 2>/dev/null
cat /mnt/id/node-image/version 2>/dev/null; echo
tail -200 /mnt/id/node-image/bootstrap.log 2>/dev/null
sudo umount /mnt/id 2>/dev/null
sudo lsblk -f /dev/nvme0n1
sudo mount -o ro /dev/nvme0n1p1 /mnt/nvme 2>/dev/null && cat /mnt/nvme/node-img.ver 2>/dev/null && sudo umount /mnt/nvme
sudo rpi-eeprom-config | grep -E '^(BOOT_ORDER|BOOT_UART)='
sudo dmesg | grep -iE 'nvme|pcie|partition|usb [0-9]' | tail -50
ip route show; curl -v --max-time 5 http://192.168.10.247:50011/node/manifest.json
```

#### Step 1 alternative — if SSH fails

| SSH failure | Likely cause | Action |
|-------------|--------------|--------|
| `No route to host` / `Network is unreachable` | Workstation not on `192.168.10.0/24` VLAN | Connect to homelab VLAN, or jumphost via Monolith. **Proceed to Experiment 2.** |
| `Connection timed out` after 30+ s | Wrong IP, or node not reachable | Re-derive IP (Step 0). If still timing out, bootstrap medium may not have come up. **Proceed to Experiment 2 + 5.** |
| `Permission denied (password)` | Password rotated or different image | Try `pi:hyperion`; check `userconf.txt` on bootstrap medium FAT partition from workstation. Otherwise **proceed to Experiment 2 + 5.** |
| `Connection refused` | sshd not running | Bootstrap image is broken; reflash bootstrap medium from known-good `rpi-bootstrap.img` and retry. |

#### Step 2 — alternative: read the live log over HTTP (no SSH required)

The bootstrap status server on `:8080` now exposes `/log` (added 2026-05-04):

```bash
curl http://<node-ip>:8080/         # JSON status (existing)
curl http://<node-ip>:8080/log      # tail -1000 of bootstrap.log
curl http://<node-ip>:8080/log?n=100
```

Returns 404 if the identity USB hasn't been mounted yet (pre-step-1). Returns 200 with the log content once the identity USB is mounted.

#### Hypothesis routing from `bootstrap.log` content

| Observation | Confirms |
|-------------|----------|
| `bootstrap.log` ends `FATAL: No HYPERION-ID USB found...` (and lists detected USBs) | H1a — wrong USB, missing label, or only bootstrap USB inserted |
| `bootstrap.log` ends `FATAL: No image in USB cache...` | H1b — Monolith unreachable AND cache empty, or H1c (literal-glob misses files) |
| `bootstrap.log` ends `NVMe is current. Clearing attempt counter. Rebooting...` | H2 — version-comparison short-circuit (`0 -ge 0` is true), or H5 (flash worked) |
| `bootstrap.log` shows successful Flash + Repartition + "Flash complete" | H5 — flash worked; user misidentified |
| `journalctl` empty / unit `failed` with no script output, `bootstrap-attempts` ≥ 3 or missing | H3 — `MAX_BOOT_ATTEMPTS` exceeded |
| `bootstrap.log` has "Flashing NVMe" then a FATAL between "Resizing" and "Flash complete" | H6 — `dd`/`partprobe` race |
| `dmesg` shows EBUSY on partition re-read | H6 confirmed |
| `dmesg` shows `nvme: error 10` or PCIe timeouts during boot | H4 — Pi 5 NVMe re-enumeration quirk (rpi-eeprom #629/#718) |
| `BOOT_ORDER` is anything other than `0xf641` | side-issue — fix with `configure-eeprom.sh` separately |

### Experiment 2 — Inspect both USBs on the workstation (5 min)

After Experiment 1 (or if SSH is blocked), pull both USBs and read on a Linux workstation:

```bash
# Identity USB
sudo mount /dev/disk/by-label/HYPERION-ID /mnt/id
ls -la /mnt/id/node-image/
cat /mnt/id/node-image/version 2>/dev/null
tail -200 /mnt/id/node-image/bootstrap.log

# Bootstrap medium FAT partition
sudo mount /dev/disk/by-label/boot /mnt/boot 2>/dev/null || sudo mount /dev/sdX1 /mnt/boot
cat /mnt/boot/bootstrap-attempts 2>/dev/null
```

`bootstrap-attempts` value diagnostic:
- `1` (or absent and log shows clean exit) → script exited cleanly first time
- `2` or `3` → script `die`d at least once
- `>3` or missing-after-three → MAX_BOOT_ATTEMPTS exceeded; status server should now (post-2026-05-04) show `status: "exhausted_attempts"` on `:8080`

### Experiment 3 — Check Monolith plumbing (1 min)

```bash
curl http://192.168.10.247:50012/        # healthcheck full report
curl http://192.168.10.247:50011/node/manifest.json | jq .
IMG=$(curl -s http://192.168.10.247:50011/node/manifest.json | jq -r .image_file)
curl -I http://192.168.10.247:50011/node/$IMG
```

If healthcheck or manifest fails: **Monolith is the root cause; do not touch the bootstrap script.**

### Experiment 4 — Verify Node IMG bakes in `node-img.ver` (1 min, regression-prevention)

```bash
grep -n node-img.ver ~/GitHub/Homelab/Hyperion/packer/rpi-node.pkr.hcl
# Expected: line 117 — echo '${var.image_version}' > /boot/firmware/node-img.ver
```

If line is missing or commented out, that would be a regression — the Bootstrap script deletes this stamp at line 422 and never rewrites it; the Node IMG must bake it in. Confirmed present today.

### Experiment 5 — UART serial console (15 min, requires hardware)

**Conditional on:** Experiments 1–3 producing inconclusive results, OR `dmesg` from Experiment 1 showing PCIe / NVMe enumeration errors that suggest H4.

**Hardware required:** USB-TTL serial adapter (3.3V — CP2102 or FT232 chipset, ~$5).

Both Bootstrap and Node IMGs now have UART boot output enabled by default (`enable_uart=1` in config.txt + `console=serial0,115200` in cmdline.txt — added 2026-05-04). Hardware connection: USB-TTL TX → Pi GPIO 15 (RX); USB-TTL RX → Pi GPIO 14 (TX); USB-TTL GND → Pi GPIO 6 (or any ground); 115200 baud.

```bash
screen /dev/ttyUSB0 115200
```

Cold-boot the failing node:
- `nvme: error 10` → H4a (rpi-eeprom #629 — NVMe needs USB-MSD present at boot)
- `PCIe timeout 0x0001e08f` → H4b (rpi-eeprom #718 — `systemctl reboot` fails to re-enumerate NVMe)

### Experiment 6 — Forced reflash with sentinel (10–15 min, destructive)

Only run if H2 is suspected. With identity USB inserted:

```bash
ssh pi@<node-ip>
ID=$(sudo blkid -L HYPERION-ID); sudo mkdir -p /mnt/id && sudo mount $ID /mnt/id
echo 0 | sudo tee /mnt/id/node-image/version
sudo umount /mnt/id
# OR:
sudo mount /dev/nvme0n1p1 /mnt/nvme && sudo rm -f /mnt/nvme/node-img.ver && sudo umount /mnt/nvme
sudo reboot
```

If the NVMe gets flashed (rapid LED + version stamp updated), **H2 is confirmed**.

---

## Networked log collection

A `journal-remote` service runs on Monolith (`docker compose up -d journal-remote`). All Hyperion nodes ship their journals to it via `systemd-journal-upload`. Logs land at `/mnt/Media-Storage/Infra-Storage/journal-remote/remote-<hostname>.journal` on Monolith.

Operator query examples:

```bash
ssh truenas_admin@192.168.10.247
sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
    --unit=hyperion-bootstrap.service --no-pager | tail -200

# All journals, last 1 hour
sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
    --since='1 hour ago'

# Specific node
sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
    _HOSTNAME=hyperion-alpha
```

The bootstrap-time `:8080/log` HTTP route covers the early-boot window before `systemd-journal-upload` has network connectivity.

---

## Multi-cause expectation

Per the dbg-nvme-not-flashing pipeline's §F closing: after applying any single-hypothesis fix, **re-run Experiment 1 to verify** the symptom is resolved AND that no new failure mode has surfaced. Multi-cause failures are the modal outcome on systems without a known-good baseline.

If the first iteration of this runbook resolves H1 but a different symptom emerges (e.g., "now the flash runs but the node won't boot Node IMG post-reboot"), open a new debugging pipeline iteration with the new evidence.

---

## Test-node selection

For Experiments 1–6 (bootstrap-stage diagnostic): any node — `hyperion-alpha` is fine.

For log-shipper validation when `journal-remote` is first stood up: prefer an **8 GB node** (two of ten Hyperion nodes are 4 GB).

---

## Cross-references

- Pipeline run: `docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/FINAL.md`
- Image build: `Hyperion/docs/runbooks/build-packer-image.md`
- EEPROM config: `Hyperion/docs/runbooks/configure-eeprom.md`
- Re-imaging at scale: `Hyperion/reimage.sh --help`, `docs/todo.md` Step 8
