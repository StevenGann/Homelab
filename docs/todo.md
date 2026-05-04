# Homelab IaC — To Do

## Status

The two-image IaC is implementation-complete and CI is green. **Current focus: get
one Hyperion node successfully imaged end-to-end, diagnose why nodes aren't
reaching NVMe boot, then scale to all 10 and finish post-imaging configuration.**

Active debug pipeline:
[`docs/pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/FINAL.md`](pipeline-runs/20260504T000719Z-dbg-nvme-not-flashing/FINAL.md).
Diagnostic runbook: [`Hyperion/docs/runbooks/debug-flashing.md`](../Hyperion/docs/runbooks/debug-flashing.md).

---

## Step A — Wait for CI to rebuild Bootstrap IMG

Recent commits (`ee41010`, `a46cc5f`, …) touched `Hyperion/packer/files/bootstrap.sh`
and the Packer files. The Bootstrap IMG must be rebuilt before Step C is meaningful.

```bash
gh run list -w 'Build Bootstrap Image' -L 3
gh run watch                                   # if a run is in progress
```

Verify ci-deploy on Monolith picked it up:

```bash
ssh truenas_admin@192.168.10.247 \
    'cat /mnt/Media-Storage/Infra-Storage/images/ci-deploy-status.json'
# bootstrap timestamp should be newer than the GitHub Actions run finish time
curl -I http://192.168.10.247:50011/bootstrap/rpi-bootstrap.img
```

---

## Step B — Deploy `journal-remote` to Monolith

Phase 1 networked log collection. Required for Step C diagnostics to land in a
queryable place rather than staying on the identity USB only.

The image is built and published by `.github/workflows/build-journal-remote-img.yml`
on every push touching `Monolith/k3s-control-plane/journal-remote/**`. After the
first successful run, **make the `homelab-journal-remote` package public** on
`https://github.com/users/StevenGann/packages/container/homelab-journal-remote/settings`
(matches the existing `homelab-ci-deploy` and `homelab-healthcheck` setup).

```bash
ssh truenas_admin@192.168.10.247

# 1. Pull the new compose file into the Dockge stack directory
cp /path/to/Homelab/Monolith/k3s-control-plane/docker-compose.yml \
   /mnt/.ix-apps/app_mounts/dockge/stacks/k3s-control-plane/docker-compose.yml

# 2. Create the journal storage directory
mkdir -p /mnt/Media-Storage/Infra-Storage/journal-remote

# 3. Pull the published image and bring up the service
cd /mnt/.ix-apps/app_mounts/dockge/stacks/k3s-control-plane
docker compose pull journal-remote
docker compose up -d journal-remote

# 4. Verify
docker compose ps journal-remote               # should show "healthy"
curl -s http://localhost:19532/ -o /dev/null -w '%{http_code}\n'   # 404 = listener up
```

Full runbook: [`Monolith/k3s-control-plane/docs/runbooks/preflight.md`](../Monolith/k3s-control-plane/docs/runbooks/preflight.md).

---

## Step C — Re-flash one Bootstrap medium and run Experiment 1

The new `bootstrap.sh` and Packer files address several diagnosed defects (better
`die()` messages, `:8080/log` route, network-online wait, post-flash `node-img.ver`
write, UART boot output baked in). Validate on hardware before touching anything else.

```bash
# Workstation — flash a fresh bootstrap medium with the new image
curl -O http://192.168.10.247:50011/bootstrap/rpi-bootstrap.img
sudo dd if=rpi-bootstrap.img of=/dev/sdX bs=4M conv=fsync status=progress
```

On one node (`hyperion-alpha` is fine — see test-node selection in the runbook):

1. Insert **both** the Bootstrap medium **and** the per-node HYPERION-ID identity USB.
2. Power on.
3. Run **Experiment 1** from `Hyperion/docs/runbooks/debug-flashing.md`:
   - Find node IP (`arp -an | grep -i 'b8:27:eb\|d8:3a:dd\|dc:a6:32'`).
   - SSH in (`ssh pi@<node-ip>`, password `raspberry`) **or** `curl http://<node-ip>:8080/log`.
   - Capture `bootstrap.log`, `journalctl -u hyperion-bootstrap.service`, `nvme0n1` partition state, EEPROM config, `dmesg | grep -iE 'nvme|pcie'`.

The runbook's hypothesis-routing table maps log content to one of H1–H6.
**Once you have the diagnostic output, post it back and we'll route to the fix branch.**

If Experiment 1 is inconclusive: run Experiments 2–3 (USB inspection, Monolith
plumbing) before resorting to Experiment 5 (UART, requires hardware).

---

## Step D — Apply hypothesis-specific fix and verify

Contingent on Step C diagnosis. Per `FINAL.md` §F:

- **H1a** (missing/mislabeled identity USB) — operator-facing runbook update; no code change.
- **H1b/H1c** (cache empty / literal-glob miss) — cache-population fix in `bootstrap.sh`.
- **H2** (version-comparison short-circuit) — `bootstrap.sh` rewrite of the `-ge` branch.
- **H3** (MAX_BOOT_ATTEMPTS exceeded) — better surfacing; status route already added.
- **H4** (Pi 5 NVMe re-enumeration, rpi-eeprom #629/#718) — bake firmware update + `PCIE_PROBE=1` into Bootstrap IMG. **Per FC NAY-fix #2: update firmware → reboot → verify version → only then write `PCIE_PROBE=1`.**
- **H5** (flash worked, user misidentified) — runbook update only.
- **H6** (`dd`/`partprobe` race) — `udevadm settle` placement fix in `bootstrap.sh`.

After landing the fix: re-image the test node, re-run Experiment 1, confirm clean
NVMe boot AND that no new failure mode emerged (multi-cause failures are the
modal outcome on never-worked systems — `FINAL.md` §F closing).

---

## Step E — Roll out to all 10 nodes

Once Step D is green on the test node:

```bash
cd ~/GitHub/Homelab/Hyperion
./reimage.sh all
```

Watch via `:8080/log` on each node, or via Monolith journal-remote query:

```bash
ssh truenas_admin@192.168.10.247
sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
    --unit=hyperion-bootstrap.service -f
```

Expected: each node flashes NVMe → reboots → boots into Node IMG → SSH-as-`owner`
works on the assigned `192.168.10.10X` address.

---

## Step F — Post-imaging configuration (Ansible)

```bash
cd ~/GitHub/Homelab/Hyperion/ansible
ansible-playbook -i inventory.yaml bootstrap.yml
# or limit to one node for incremental verification:
ansible-playbook -i inventory.yaml bootstrap.yml --limit hyperion-alpha
```

---

## Step G — k3s and FluxCD

- [ ] Bring k3s online on the worker nodes (`server` already running on Monolith).
- [ ] Bootstrap FluxCD against `Hyperion/k8s/`.
- [ ] Migrate existing workloads into `Hyperion/k8s/apps/`.

---

## Re-imaging a node (ongoing)

```bash
# 1. Insert Bootstrap medium (SD card or USB stick) into target node
# 2. Trigger reboot:
cd ~/GitHub/Homelab/Hyperion
./reimage.sh hyperion-alpha     # or: ./reimage.sh all

# Bootstrap handles the rest automatically.
# 3. Remove Bootstrap medium after node is back on NVMe.
```

CI publishes a new Node IMG automatically on every push to `main` that touches
`Hyperion/packer/rpi-node.pkr.hcl` or `Hyperion/packer/files/**`.

---

## Node storage layout

| Partition | Size | FS | Mount | Purpose |
|-----------|------|----|-------|---------|
| `nvme0n1p1` | 512 MB | FAT32 | — | Pi 5 boot firmware |
| `nvme0n1p2` | 32 GB | ext4 | `/` | Root OS |
| `nvme0n1p3` | ~220 GB | ext4 | `/mnt/node-storage` | Node-local ephemeral storage |

`/mnt/node-storage` mount logic (via `detect-node-storage.service`):
- USB stick labeled `node-storage-usb` → use it
- Any USB block device >200 GB → use its first partition
- Otherwise → use `nvme0n1p3`
