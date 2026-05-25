# Phase 3 — Configuration

> **Status:** ongoing operational work. **There is no acceptance gate for Phase 3.**
> The Heimdall *project* is complete at the end of Phase 2 (the end-to-end self-test
> proves the stack is usable). Phase 3 is steady-state operations: adding routes,
> records, and external port-forwards as services come and go.

## What Phase 3 covers

- Adding `.lab` DNS records via `seed-zones.sh` or the Technitium UI.
- Adding Caddyfile `reverse_proxy` blocks for new services.
- Adding Caddyfile `layer4` stanzas for new game-server / non-HTTP traffic.
- UCG-side: DHCP option 6, WAN port-forwards.
- Caddy internal-CA root distribution to new LAN clients.
- Pre-merge sanity checks (re-running `seed-zones.sh`; running the LAN smoke-test).

## `seed-zones.sh` contract — additive-only

The script POSTs to Technitium's HTTP API and is intentionally **additive-only**:

| Operation | What the script does |
|---|---|
| Zone doesn't exist | Creates it via `POST /api/zones/create?zone=lab&type=Primary`. |
| Zone exists | Skips create (idempotent). |
| Record in `RECORDS=()` doesn't exist in Technitium | Adds it via `POST /api/zones/records/add` with the type-appropriate rdata param. |
| Record in `RECORDS=()` already matches (same name+type+rdata) | Skips (idempotent). |
| Record in Technitium but NOT in `RECORDS=()` | **Untouched. The script never deletes.** |
| Record in Technitium with same name+type but different rdata | **Untouched. The script does NOT update existing records.** |

What this means in practice:

- **Operator UI-added records persist across `seed-zones.sh` runs.** You can add ephemeral `experimental.lab` records via the Technitium UI during testing without worrying about the script removing them later.
- **Removing a record from the declaration set does NOT remove it from Technitium.** If you want to delete a record, do it via the UI (or curl the `/api/zones/records/delete` endpoint manually).
- **Changing a record's rdata in the declaration set does NOT update Technitium.** Same — delete then re-add.

This is "scriptable scaffolding," not Terraform-style reconciliation. The full diff-and-apply contract was deliberately not built; see the pipeline run's iter-1 04-revision.md §C C4 for the team's reasoning.

### Retry behavior

Exponential backoff on 5xx (1s, 2s, 4s); 3 retries. Logical errors (Technitium responds with `{"status":"error"}`) are NOT retried — the script terminates non-zero and leaves zone state intact.

## Adding a new `.lab` record

Edit the `RECORDS=()` array at the top of `Heimdall/scripts/seed-zones.sh`:

```bash
RECORDS=(
    "komodo.lab|A|192.168.10.4"
    "new-service.lab|A|192.168.10.4"     # ← new entry
)
```

Then:

```bash
git add Heimdall/scripts/seed-zones.sh
git commit -m "dns: add new-service.lab"
git push
# After Komodo pulls latest (drift detection or operator clicks):
bash /opt/Homelab/Heimdall/scripts/seed-zones.sh
```

The script will see the new entry, GET the existing records, find the new record absent, and POST it. Existing records stay untouched.

## Adding a new HTTPS route via Caddy

See [`adding-a-route.md`](adding-a-route.md) for the per-route pattern (NodePort fanout across all Pi nodes, health checks, internal CA).

## Drift detection in Komodo

`KOMODO_RESOURCE_POLL_INTERVAL=1-hr` is set in `docker-compose.yml`. Komodo Core polls the running container image digests every hour and compares against the Stack manifest's pinned digest.

**What drift means here:**

- **Actionable drift:** the running image digest doesn't match what's in `Heimdall/docker-compose.yml` on `main`. This usually means the operator pulled an image manually (e.g., `docker compose pull`) but hasn't yet recreated the container.
- **Informational drift (false-positive-ish):** a Dependabot or `poll-caddy-l4-releases.yml` PR is open with a new image tag but hasn't been merged. The Stack is on the old tag; the new tag exists upstream. This will appear as drift until the PR is merged and `docker compose pull` runs.

Expected alert volume: ~2–4/week steady state, mostly the second case. Operator triages from Komodo UI's update view.

## Cross-host port-forwards (UCG side)

On the UCG, after Heimdall is reachable on `192.168.10.4`:

| Port | Forward to | Why |
|------|-----------|-----|
| 443/tcp + 443/udp | `192.168.10.4` | HTTPS + HTTP/3 (Caddy) |
| 25565/tcp + 25565/udp | `192.168.10.4` | Minecraft TCP + Bedrock UDP (Caddy L4) |
| Additional game ports | `192.168.10.4` | Per game server, when added |

**Do not** forward port 80 from WAN. The :80 listener on Heimdall is LAN-only (for the `/ca.crt` distribution endpoint).

DHCP option 6 (DNS servers) on the UCG:

- Primary: `192.168.10.4` (Heimdall / Technitium)
- Secondary: `1.1.1.1` (the SPOF mitigation slot — see [iter-1 §C3](../../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md))

## The 6-month Technitium-secondary deadline

Per the finalize run's action-tagged deadline mechanism:

- Add to `docs/todo.md` at Phase 2 completion: target date = Phase-2-completion + 6 months.
- At month 6, two binary outcomes only:
  - (a) Revert Heimdall from Technitium to AdGuard Home.
  - (b) Deploy the Akasha-side Technitium secondary in that month's scheduled pipeline run.
- "Defer further" is not an outcome.

If month 6 arrives and Technitium is still standalone, the swap's named justification (DNS HA via clustering) has not materialized, and the team commits to either retracting the swap or making the secondary land.

## Monitoring footnotes

- **Mongo working-set growth.** `--wiredTigerCacheSizeGB 0.25` caps the WT cache at 250 MB. Total Mongo RSS typically settles at 500-1000 MB in steady state with audit log + Stack history. Investigate via `docker exec komodo-mongo mongosh --eval 'db.serverStatus()'` only if RSS exceeds 2 GB. Heimdall has 32 GB RAM; this is monitoring, not a capacity concern.
- **Caddy + 10 NodePort upstreams.** At 30s/60s health interval per upstream, the cluster receives ~20 active checks/minute per HTTP route. For ≤20 routes this is sub-1 RPS background traffic — fine.
- **Backup job.** `Heimdall/scripts/backup.sh` runs nightly via the cron entry installed by `setup.sh` (TODO if not yet wired). Snapshots `caddy/data/`, `technitium/config/`, `komodo-data/mongo-data/`, `komodo-data/keys/` to `akasha:/mnt/Media-Storage/Infra-Storage/heimdall-backups/<DATE>/` with 30-day retention.
