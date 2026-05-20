# Heimdall — Reconstruction from scratch

> **Premise:** Heimdall's hardware has failed catastrophically (NVMe corruption,
> motherboard failure, etc.). You have a replacement box, this repo, the SOPS age
> private key, and GitHub access. Bring Heimdall back to its pre-failure state.
>
> **Total walk-clock target:** ≤ 1 hour from blank Ubuntu install to passing the
> Phase 2 end-to-end self-test.

## Inputs required

1. Replacement hardware on the network.
2. Ubuntu Server 26.04 LTS install media.
3. This repo (clonable from `https://github.com/StevenGann/Homelab.git`).
4. SOPS age private key (`~/.config/sops/age/keys.txt`) — this is the only secret you need; everything else is in SOPS-encrypted form in the repo.
5. The most recent backup snapshot from Monolith (optional — for cert-store and DNS-zone continuity; see "Restore optional state" below).

## Reconstruction steps

### 1. Run Phase 1 on the replacement hardware

Follow [`phase-1-host.md`](phase-1-host.md). This installs Ubuntu, runs `setup.sh`, and brings the host to the same baseline state Phase 1 leaves any new Heimdall in. Critical pre-reqs to flip on after Phase 1 lands and before deploy.sh can run unattended:

```bash
# Passwordless sudo for owner (deploy.sh's auto-fix steps need this)
ssh -t owner@<heimdall-ip> \
    'echo "owner ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/owner-nopasswd && sudo chmod 0440 /etc/sudoers.d/owner-nopasswd'

# SSH key auth from workstation (deploy.sh runs unattended over SSH)
ssh-copy-id owner@<heimdall-ip>
```

### 2. Restore optional state (if recovering)

Before starting the containers in Phase 2, decide whether to restore from backup:

| State to restore | Effect of NOT restoring |
|---|---|
| `caddy/data/` (internal-CA root + ACME accounts) | Caddy generates a NEW internal-CA root on first start. Every LAN client must re-trust the new root — disruptive. |
| `technitium/config/` (zone records, blocklist subscriptions, admin user) | `seed-zones.sh` re-creates the `.lab` zone and declared records. Operator UI-added ephemeral records are lost. |
| `komodo-data/mongo-data/` (Komodo audit log + Stack history) | Komodo Core comes up fresh — all Stack configuration history lost. The current Stack definition (in `docker-compose.yml`) is restored from the repo. |
| `komodo-data/keys/` (Komodo internal Ed25519 keys) | Komodo generates new keys; Periphery re-onboards cleanly on next `onboard-periphery.sh` run. |

If restoring (recommended for `caddy/data/` at minimum):

```bash
# From a backup on Monolith — pick the most recent snapshot.
LATEST=$(ssh truenas_admin@192.168.10.247 \
    'ls -1 /mnt/Media-Storage/Infra-Storage/heimdall-backups/ | sort | tail -1')

# Restore each path. Be careful: rsync --delete on restore is the right
# semantics ONLY if you trust the backup as the canonical state.
rsync -a "truenas_admin@192.168.10.247:/mnt/Media-Storage/Infra-Storage/heimdall-backups/${LATEST}/caddy/data/" \
    /opt/Homelab/Heimdall/caddy/data/

rsync -a "truenas_admin@192.168.10.247:/mnt/Media-Storage/Infra-Storage/heimdall-backups/${LATEST}/technitium/config/" \
    /opt/Homelab/Heimdall/technitium/config/

rsync -a "truenas_admin@192.168.10.247:/mnt/Media-Storage/Infra-Storage/heimdall-backups/${LATEST}/komodo-data/mongo-data/" \
    /opt/Homelab/Heimdall/komodo-data/mongo-data/

rsync -a "truenas_admin@192.168.10.247:/mnt/Media-Storage/Infra-Storage/heimdall-backups/${LATEST}/komodo-data/keys/" \
    /opt/Homelab/Heimdall/komodo-data/keys/
```

### 3. Run Phase 2 — one command

```bash
# On the workstation:
cd ~/GitHub/Homelab
bash Heimdall/scripts/deploy.sh
```

That runs the entire Phase 2 sequence end-to-end: decrypt secrets, ship to Heimdall, `docker compose up -d`, onboard Periphery to Komodo Core, seed the Technitium `.lab` zone. See [`phase-2-containers.md`](phase-2-containers.md) for what each step does internally.

If `deploy.sh` exits 0, distribute the Caddy internal-CA root to LAN clients (per [`trust-store-distribution.md`](trust-store-distribution.md)) and confirm the Phase 2 acceptance gate: `curl -fsS https://komodo.lab` from a trusted LAN client returns Komodo's UI HTML.

## Verification (post-reconstruction)

In addition to Phase 2's acceptance checklist:

- LAN clients that trusted the previous internal-CA root: if you restored `caddy/data/`, no re-trust is needed. If not, distribute the new root per [`trust-store-distribution.md`](trust-store-distribution.md).
- UCG DHCP option 6 should still point at `192.168.10.4`. Verify: a fresh DHCP-leased LAN client receives Heimdall as primary DNS.
- All Phase 3 routes that existed pre-failure work. Walk the Caddyfile blocks and curl-test each.

## What is NOT covered by reconstruction

- **External-internet exposure for new services.** UCG port-forwards must be reviewed; they may need to be updated to point at the new Heimdall IP (if it changed from `.4`).
- **Active Komodo Stacks that Heimdall manages on OTHER hosts.** This is a Phase 4 / Monolith-migration concern.

## Failure modes during reconstruction

- **`setup.sh` step 8 fails to install Periphery.** Periphery's installer fetches from `raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py`. If GitHub is unreachable, this fails. Recovery: cache `setup-periphery.py` somewhere reachable (Monolith?) and override the URL.
- **`onboard-periphery.sh` fails because Komodo Core can't authenticate.** If you restored Mongo from backup, the admin user's bcrypt hash is the backed-up one — your `.env`'s `KOMODO_INIT_ADMIN_PASSWORD` must match. If you started Mongo fresh, Komodo Core seeds the admin from `.env`. Pick one.
- **Caddy reuses the OLD ACME-account key but the public LE thinks it's tied to a different IP.** Only relevant if you flipped any hostname to public LE. Internal-CA default (the v1 plan) avoids this entirely.

## How long this should actually take

| Step | Time |
|------|------|
| Ubuntu install | 15-20 min |
| `setup.sh` run | 5-10 min (depends on apt mirror speed) |
| SOPS decrypt | < 1 min |
| `docker compose pull` | 5-15 min (depends on registry response) |
| `docker compose up -d` + first-start initialization | 2-3 min |
| `onboard-periphery.sh` | < 1 min |
| `seed-zones.sh` | < 1 min |
| End-to-end self-test | < 1 min |

**Total: ~30-45 minutes.** Comfortably under the 1-hour target.

If reconstruction routinely exceeds 1 hour, the runbook is broken; file an issue.
