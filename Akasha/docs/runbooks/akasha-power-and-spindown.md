# OPERATOR RUNBOOK — Akasha HDD spin-down & power reduction

> **Verified 2026-09-09.** Documents the electricity-reduction work on Akasha
> (TrueNAS Scale 25.04 @ `192.168.10.247`): why the 13 HDDs would not spin down,
> the root cause, and everything now in place to keep them spun down when idle.
> Baseline was 516 W (4.3 A) for the whole rack.

## Goal
Reduce Akasha's idle power by making the HDDs reach `standby` (platters stopped)
during idle periods, as often as possible.

## 1. First, the I/O had to be eliminated
A steady read/write stream defeats any idle timer — the drive never idles. The
following were retired or rescheduled (see `references/media-stack-io-sources.md`
in the homelab-ops skill for the full account):

- **Tdarr** — retired entirely (stuck `NaN` scan loop after the worker GPU node
  was removed; 46-pod churn). Manifests removed from Flux; PVC deleted.
- **qBittorrent** — seeding limits normalized (ratio 1.0 / 24 h seed / 15 uploads)
  across all three instances; ~430 completed/stalled torrents purged (~2.3 TB freed).
- **Jellyfin trickplay** — moved from a 24/7 unbounded daily job to a 2 AM window
  with a 6 h max runtime.
- **qBittorrent schedule** — `/mnt/App-SSD/scripts/qb-schedule.py` (cron id=2,
  every 5 min) pauses all torrents 09:00–21:00 and resumes 21:00–09:00 (America/Los_Angeles).

After these, the pool reached **zero I/O** during the day — but the drives still
reported `active/idle`, not `standby`. That kicked off the timer investigation.

## 2. The standby timer cannot be set on these drives
- `hddstandby=5` is already set per-disk in TrueNAS, but it is **not reaching the
  drives**. The ATA standby timer is the wrong mechanism here.
- These SATA drives sit behind a **SAS HBA**, which drives power via the **SCSI
  power-condition mode page**, not the ATA timer. So `hdparm -S 60` writes a
  timer the HBA ignores.
- `sdparm --set=STANDBY_Z=1 --set=SZCT=3000` is **rejected**: the mode page is
  "not saveable" (exit 97) — the drive/SAT layer won't take a power-condition
  change at all.
- Net effect: `IDLE_A/B=1` (from `advpowermgmt=1`) only **parks heads** — the
  platters keep spinning. **The only reliable mechanism is explicit `hdparm -y`**
  (standby now), which does work.

## 3. The real wake-up cause — root-caused with bpftrace
Drives spun down with `hdparm -y` still returned to `active/idle` every ~60 s. It
was **not** a control command (SMART/`hdparm -C`), and **not** data I/O (`/proc/diskstats`
was frozen). It was a small ZFS **data** write: the **uberblock**.

- ZFS writes the uberblock to **every vdev on every `spa_sync`**.
- The sync was being forced ~every 60 s by the TrueNAS **system dataset** living
  on the spinning pools (`App-Storage/.system` + a stale copy on `Media-Storage/.system`).
- netdata (dbengine metrics, writes every ~1 s), syslog, samba4 and cores all write
  continuously → constant dirty data → constant `spa_sync` → uberblock to every HDD
  → wake + idle-timer reset.

**How it was found** (methodology worth keeping):
- `strace` is not installed on TrueNAS Scale, but **`bpftrace` is**.
- Traced `tracepoint:scsi:scsi_dispatch_cmd_start` filtered to one drive
  (`host_no==0 && channel==0 && id==0`), printing `opcode` + `comm`.
- `z_null_iss … op=0x8a` = uberblock writes; `z_wr_iss/z_wr_int` = data writes.
- `kprobe:zfs_write` / `zfs_read` / `zfs_putpage` with `@[comm]=count()` traced the
  **user-space** writers → `syslog-ng` + `auditd` → back to the system dataset.

## 4. Fixes applied
| # | Change | Effect |
|---|--------|--------|
| 1 | **Moved the system dataset to SSD** — `midclt call systemdataset.update '{"pool":"App-SSD"}'` | Stops the continuous system writes that forced uberblock writes; drives now stay in standby 6+ min |
| 2 | **SMART Power Mode → Standby** — `midclt call smart.update '{"powermode":"STANDBY"}'` + `systemctl restart smartd` | smartd no longer wakes each disk to read SMART (was `-n never`) |
| 3 | **Cron auto-spin-down** — `/mnt/App-SSD/scripts/hdd-autospindown.sh` (cron id=3, `*/10`) | Since the hardware timer can't be set, explicitly `hdparm -y` the drives after 2 min of zero I/O |

**`hdd-autospindown.sh`** snapshots `/proc/diskstats` (reads/writes per drive)
twice 120 s apart; if unchanged (no data I/O on any of the 13 drives) it issues
`hdparm -y` on all of them. Safe: any active I/O during the window skips the spin-down.

## 5. Current state
- **Day** (09:00–21:00, torrents paused): drives spin down within ~10–12 min of
  idle and stay down — roughly **60–90 W** off the baseline.
- **Night**: drives spin up for torrents, then re-sleep when idle again.
- All 13 drives reach and hold `standby` (verified 6+ min).

## 6. Leftover cleanup (noted, not done)
The old system-dataset copies are orphaned after the move and are **no longer
written to** — `Media-Storage/.system` (~2.1 GB) and `App-Storage/.system`.
Left in place by request; destroy later to reclaim ~2 GB if desired. **Do not
recreate the system dataset on a spinning pool.**

## 7. SMR caveat
The 8× ST8000DM004 are **SMR** drives. SMR drives do deferred band housekeeping
during idle; aggressive spin-down interrupts it → write-latency spikes on wake +
extra wear. 15–30 min standby is a better balance than the current aggressive
approach if this becomes a problem; for now the "spin down as often as possible"
directive takes precedence.

## 8. Reference commands
```bash
# Drive state (non-waking): standby vs active/idle
sudo hdparm -C /dev/sdX

# Immediate spin-down (the only working mechanism)
sudo hdparm -y /dev/sdX

# System dataset location
sudo midclt call systemdataset.config

# SMART power mode (should be STANDBY)
sudo midclt call smart.config

# Per-vdev I/O (last block is the delta; first is cumulative since boot)
sudo zpool iostat -v Media-Storage 3 2

# Which datasets are being written (large = continuous writer)
sudo zfs get -r written App-Storage Media-Storage

# bpftrace: what touches a drive (map device via lsscsi first)
sudo lsscsi
sudo bpftrace -e 'tracepoint:scsi:scsi_dispatch_cmd_start /args->host_no==0 && args->id==0/ { printf("%s(%d) op=0x%02x\n", comm, pid, args->opcode); }'
```

## 9. Drive inventory (2026-09)
- **Media-Storage** (59.9T, ~53T used): raidz2-0 = 8× ST8000DM004 8TB **SMR** +
  special (2× PM863a mirror) + logs (1× PM863a) + cache (1× 860 EVO).
- **App-SSD** (1× PM863a) — system dataset now lives here.
- **App-Storage** (2× HGST 4TB mirror), **Jellyfin-SSD**, **boot-pool** (NVMe).
- 3 unassigned HDDs (sdf 2TB, sdg/sdq 4TB HGST) — spun down via `hdparm -Y`.
- The 13 spin-down targets: `sda sdb sdd sdh sdj sdk sdl sdm sdr sdo sdf sdg sdq`.
