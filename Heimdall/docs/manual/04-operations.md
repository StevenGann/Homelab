# 04 — Daily operations

> Recipe-style how-tos for common operator tasks. Each one names the prerequisites, the steps, and where to verify.

## Index

- [Add an HTTPS route](#add-an-https-route)
- [Add a `.lab` DNS record](#add-a-lab-dns-record)
- [Block a domain in Technitium](#block-a-domain-in-technitium)
- [Add or update a Technitium blocklist subscription](#add-or-update-a-technitium-blocklist-subscription)
- [Deploy a new container / Stack via Komodo](#deploy-a-new-container--stack-via-komodo)
- [Add an L4 (game-server / non-HTTP) route](#add-an-l4-game-server--non-http-route)
- [Restart, stop, or recreate a container](#restart-stop-or-recreate-a-container)
- [Use the per-container browser terminal in Komodo](#use-the-per-container-browser-terminal-in-komodo)
- [Check logs](#check-logs)
- [Rotate the Komodo admin password](#rotate-the-komodo-admin-password)
- [Rotate the Technitium admin password](#rotate-the-technitium-admin-password)
- [Roll a Komodo / Mongo / Technitium image to a new version](#roll-a-komodo--mongo--technitium-image-to-a-new-version)
- [Bump the Caddy / caddy-l4 image (custom build)](#bump-the-caddy--caddy-l4-image-custom-build)
- [Re-onboard Periphery (when the trust state breaks)](#re-onboard-periphery-when-the-trust-state-breaks)
- [Add a new LAN device to the Caddy CA trust](#add-a-new-lan-device-to-the-caddy-ca-trust)
- [Take a backup snapshot manually](#take-a-backup-snapshot-manually)
- [Restore a single file from a backup snapshot](#restore-a-single-file-from-a-backup-snapshot)
- [Find a secret](#find-a-secret)

---

## Add an HTTPS route

You want `https://my-service.lab` to route through Caddy to a backend.

**Prerequisites:** the backend service is reachable from Heimdall by IP. For k3s services on Hyperion, that means the Service is `type: NodePort`.

**Steps:**

1. **Edit `Heimdall/caddy/Caddyfile`.** Add a block:

   ```caddy
   my-service.lab {
       tls internal

       # For a single backend (e.g., another Komodo-managed container on Heimdall):
       reverse_proxy 127.0.0.1:8080

       # OR — for a k3s service with NodePort fanout across all Pi nodes:
       # reverse_proxy 192.168.10.101:30100 192.168.10.102:30100 \
       #               192.168.10.103:30100 192.168.10.104:30100 \
       #               192.168.10.105:30100 192.168.10.106:30100 \
       #               192.168.10.107:30100 192.168.10.108:30100 \
       #               192.168.10.109:30100 192.168.10.110:30100 {
       #     lb_policy least_conn
       #     health_uri /healthz
       #     health_interval 30s
       #     fail_duration 60s
       # }
   }
   ```

   Pick **either** the single-backend form (no health check needed) **or** the multi-NodePort form (active health check probes a service-specific known-good path).

2. **Add a DNS record** for `my-service.lab` — see [Add a `.lab` DNS record](#add-a-lab-dns-record).

3. **For external access (optional):** add a UCG WAN port-forward for 443 → `192.168.10.4` if not already there.

4. **Commit, push, deploy:**

   ```bash
   git add Heimdall/caddy/Caddyfile Heimdall/scripts/seed-zones.sh
   git commit -m "caddy: add my-service.lab route"
   git push
   bash Heimdall/scripts/deploy.sh --no-secrets
   ```

   `deploy.sh` detects Caddyfile changed and restarts the Caddy container (working around the file-bind-mount inode pinning).

**Verify:**
```bash
dig @192.168.10.4 my-service.lab        # → 192.168.10.4
curl -fsS https://my-service.lab/health # backend's health endpoint, status 200
```

See also: [`runbooks/adding-a-route.md`](../runbooks/adding-a-route.md) for the full Caddyfile pattern reference + NodePort allocation policy.

---

## Add a `.lab` DNS record

Two paths depending on whether the record is permanent (versioned in git) or ephemeral (operator-tweak in the UI).

### Permanent (preferred — committed to the repo)

1. Edit [`Heimdall/scripts/seed-zones.sh`](../../scripts/seed-zones.sh) and add to the `RECORDS=()` array:

   ```bash
   RECORDS=(
       "komodo.lab|A|192.168.10.4"
       "my-service.lab|A|192.168.10.4"      # ← new
   )
   ```

   Format: `name|type|rdata[|ttl]`. Supported types: `A`, `AAAA`, `CNAME`, `NS`. Add more in the script's `case "$rtype"` block if needed.

2. Commit + push + redeploy:

   ```bash
   git add Heimdall/scripts/seed-zones.sh
   git commit -m "dns: add my-service.lab"
   git push
   bash Heimdall/scripts/deploy.sh --no-secrets
   ```

   `seed-zones.sh` (additive-only) GETs the existing records, finds the new one absent, and POSTs it. Existing records (operator UI-added or otherwise) are untouched.

### Ephemeral (UI — for testing or short-lived hosts)

Browse to `http://192.168.10.4:5380` → log in → Zones → `lab` → Add Record. Records added this way are NOT in git; they persist in `Heimdall/technitium/config/` on Heimdall but are lost if you tear down `technitium/config/` and don't restore it.

**Verify:**
```bash
dig @192.168.10.4 my-service.lab
```

---

## Block a domain in Technitium

Two ways.

### Ad-hoc (single domain via UI)

1. Open Technitium UI: `http://192.168.10.4:5380`.
2. **Settings → Blocking → Blocked Domains** (or similar — Technitium UI labels vary by version).
3. Add `bad.example.com`. Save.

This is a manual blocklist entry. Persists in `dns.config`.

### Via a blocklist subscription

See [Add or update a Technitium blocklist subscription](#add-or-update-a-technitium-blocklist-subscription).

**Verify:**
```bash
dig @192.168.10.4 bad.example.com
# → returns 0.0.0.0 / ::0 (sinkhole)
```

---

## Add or update a Technitium blocklist subscription

Two paths — the **IaC path** (recommended; reconstruction-safe) and the **UI path** (quick one-off).

### IaC path — `seed-blocklists.sh`

The canonical list of subscriptions lives in [`Heimdall/scripts/seed-blocklists.sh`](../../scripts/seed-blocklists.sh)'s `BLOCK_LIST_URLS` array. Each `deploy.sh` run reconciles Technitium to match the array.

```bash
# Edit the array:
$EDITOR Heimdall/scripts/seed-blocklists.sh

# Commit + push + deploy:
git add Heimdall/scripts/seed-blocklists.sh
git commit -m "blocklists: add <name>"
git push
bash Heimdall/scripts/deploy.sh --no-secrets
```

**Contract — different from `seed-zones.sh`:**
- `seed-blocklists.sh` uses **reconciling** semantics. The array IS the canonical set; UI-added URLs not in the array are REMOVED on next deploy.
- `seed-zones.sh` uses **additive** semantics. UI-added records persist.

The asymmetry is intentional: DNS records are routinely added/removed during testing (additive matches that workflow); blocklists are deliberate, infrequent configuration (reconciliation matches that).

Also reconciled by the script (idempotent per run):
- `enableBlocking=true`
- `blockingType=NxDomain`
- `blockListUpdateIntervalHours=24`
- Triggers an immediate refresh after subscription changes (otherwise Technitium waits up to 24h for the next scheduled fetch).

### UI path — quick one-off

For testing or rapid iteration:

1. Technitium UI → **Settings → Blocking → Block List URLs**.
2. Add the URL → Save → **Update Now**.

⚠ Anything you add via the UI is wiped on the next `deploy.sh`. If you want it permanent, add it to `seed-blocklists.sh` instead.

### Recommended URLs (current declared set)

| URL | Coverage |
|---|---|
| `https://big.oisd.nl` | Ads, trackers (broad daily-driver list) |
| `https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt` | AdGuard Base (ads + trackers) |
| `https://urlhaus.abuse.ch/downloads/hostfile/` | Malware (abuse.ch curated) |
| `https://phishing.army/download/phishing_army_blocklist_extended.txt` | Phishing |

The blocklist subscription set lives in `dns.config` inside `Heimdall/technitium/config/` (bind-mounted, persistent across container restarts). The seed script reconciles it back to the declared array on each run.

---

## Deploy a new container / Stack via Komodo

Komodo manages "Stacks" (Compose-file-shaped deployments). To deploy a new application:

1. Open Komodo: `https://komodo.lab`.
2. **Stacks → Create Stack**.
3. Configure:
   - Name (e.g., `gitea`)
   - Server: `heimdall` (the only one for now)
   - Source: paste a compose file inline, OR point at a Git repo path
4. Save → **Deploy**.

Komodo writes the compose file to `Heimdall/komodo-data/repos/<stack>/...`, runs `docker compose up -d` via Periphery, and the new containers appear in the UI.

For Stacks managed in this repo (recommended for reconstruction), the compose file should live somewhere under `Heimdall/` (or a sibling directory you create) and be Git-tracked. Komodo polls Git on its `KOMODO_RESOURCE_POLL_INTERVAL` (1h) and surfaces drift in the UI.

**Recommended pattern:** for each new Stack, create `<host>/<stack-name>/docker-compose.yml` in the repo. Drift becomes "the repo says X, the running container says Y" — exactly the question Komodo's drift UI is built to answer.

---

## Add an L4 (game-server / non-HTTP) route

For Minecraft, SFTP, RCON, raw TCP/UDP traffic — `caddy-l4` handles these via the Caddyfile `layer4` directive.

1. Edit `Heimdall/caddy/Caddyfile`. Add a top-level `layer4` global block (or extend it if one exists):

   ```caddy
   {
       layer4 {
           :25565 {
               route {
                   proxy minecraft.lab:25565
               }
           }
           :25565/udp {
               route {
                   proxy udp/minecraft.lab:19132
               }
           }
       }
   }
   ```

2. **DNS:** add `minecraft.lab` → wherever the actual game server runs (Heimdall, Akasha, a Pi). See [Add a `.lab` DNS record](#add-a-lab-dns-record).

3. **nftables:** the port must be in `Heimdall/hostconf/nftables.conf`'s allow-list. Edit, commit, then re-apply: `sudo bash setup.sh --force 04_nftables` on Heimdall.

4. **UCG WAN port-forward:** add a rule for the port → `192.168.10.4` if external access is needed.

5. Commit + push + `bash Heimdall/scripts/deploy.sh --no-secrets`.

**Caveat:** game servers should typically run as **non-k8s containers** (on Heimdall itself or another host) because default NodePort range (30000-32767) doesn't include common game ports.

---

## Restart, stop, or recreate a container

### Via Komodo UI (preferred for ad-hoc)

`https://komodo.lab` → Servers → heimdall → Containers → click the container → Restart / Stop / Start.

The audit log records who did what when.

### Via the host shell

```bash
ssh owner@192.168.10.4

# Soft restart (container stays, process restarts):
docker compose -f /opt/Homelab/Heimdall/docker-compose.yml restart caddy

# Recreate (kills + creates a fresh container with current compose-file settings):
docker compose -f /opt/Homelab/Heimdall/docker-compose.yml up -d --force-recreate caddy

# Stop (container exits but stays defined):
docker compose -f /opt/Homelab/Heimdall/docker-compose.yml stop caddy

# Bring everything down (containers gone, bind-mount data preserved):
docker compose -f /opt/Homelab/Heimdall/docker-compose.yml down

# Bring everything back:
docker compose -f /opt/Homelab/Heimdall/docker-compose.yml up -d
```

`down + up` is the canonical fix when bridge networking gets into a weird state (see [troubleshooting](06-troubleshooting.md)).

---

## Use the per-container browser terminal in Komodo

The headline reason we chose Komodo over Dockge.

1. `https://komodo.lab` → Servers → heimdall → Containers → click any container.
2. **Terminal** tab.
3. Bash shell inside the running container.

For an exec into a specific command (e.g., `mongosh`):
```bash
# From the workstation, via SSH:
ssh owner@192.168.10.4 \
    'docker compose -f /opt/Homelab/Heimdall/docker-compose.yml exec mongo mongosh -u admin'
```

---

## Check logs

### Per-container (recent)

```bash
ssh owner@192.168.10.4 \
    'docker compose -f /opt/Homelab/Heimdall/docker-compose.yml logs --tail=50 caddy'
```

Or, from Komodo UI: container → Logs tab.

### Per-container (follow live)

```bash
ssh owner@192.168.10.4 \
    'docker compose -f /opt/Homelab/Heimdall/docker-compose.yml logs -f caddy'
```

### Host-side service (e.g., Periphery)

```bash
ssh owner@192.168.10.4 'sudo journalctl -u periphery -n 80 --no-pager'
```

### Centralized on Akasha (Heimdall's full journal)

```bash
ssh truenas_admin@192.168.10.247 \
    'sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
         --identifier=heimdall -n 100'
```

Filter by container name (CONTAINER_NAME journald field is populated automatically by the journald log driver):
```bash
ssh truenas_admin@192.168.10.247 \
    'sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ \
         CONTAINER_NAME=heimdall-komodo-core-1 -n 100'
```

---

## Rotate the Komodo admin password

The `KOMODO_INIT_ADMIN_PASSWORD` env var only seeds the admin user on Mongo's **first** start. Editing the env var afterward and redeploying does *not* change Mongo's stored password.

To rotate:

1. Komodo UI → Profile (top right) → **Update Password**.
2. (Recommended) Also update `KOMODO_INIT_ADMIN_PASSWORD` in `Heimdall/secrets/env.sops.env` so reconstruction-from-scratch uses the new password:

   ```bash
   # On workstation:
   sops Heimdall/secrets/env.sops.env       # opens in $EDITOR; encrypts on save
   ```

   Edit the password value, save, exit. SOPS re-encrypts in place.

3. Commit + push. No deploy needed (existing running Komodo Core continues to honor its in-Mongo password; the SOPS update is for future reconstruction).

---

## Rotate the Technitium admin password

Technitium has its own user-management UI.

1. Technitium UI → **Settings → User Management** → admin user → Change Password.
2. Update `Heimdall/secrets/technitium-admin-pw.sops` to match (so future reconstructions / re-deploys ship the new value):

   ```bash
   # On workstation:
   sops --decrypt --input-type binary --output-type binary \
        Heimdall/secrets/technitium-admin-pw.sops > /tmp/tpw
   echo "NEW-PASSWORD-HERE" > /tmp/tpw
   sops --encrypt --age "$(grep '^# public key:' ~/.config/sops/age/keys.txt | awk '{print $4}')" \
        --input-type binary --output-type binary /tmp/tpw > Heimdall/secrets/technitium-admin-pw.sops
   rm /tmp/tpw
   ```

3. Commit + push. Re-deploy is optional — `seed-zones.sh` will use the new password when next invoked.

---

## Roll a Komodo / Mongo / Technitium image to a new version

These are upstream images, version-pinned in `Heimdall/docker-compose.yml`.

1. Check upstream release notes:
   - Komodo: <https://github.com/moghtech/komodo/releases>
   - Mongo: <https://hub.docker.com/_/mongo>
   - Technitium: <https://github.com/TechnitiumSoftware/DnsServer/releases>
2. Edit the `image:` line in `Heimdall/docker-compose.yml`.
3. Commit + push + `bash Heimdall/scripts/deploy.sh --no-secrets`. `docker compose pull` fetches the new tag; `up -d` recreates only the changed service.
4. (Mongo specifically:) major-version bumps may require a migration step — check the release notes. Minor bumps are generally safe.

Dependabot also tracks the `FROM` lines in `Heimdall/caddy/image/Dockerfile` and will open PRs for Caddy base-image bumps.

---

## Bump the Caddy / caddy-l4 image (custom build)

The Caddy image is a custom build with the `caddy-l4` plugin baked in. Two version pins live in [`Heimdall/caddy/image/Dockerfile`](../../caddy/image/Dockerfile):

- **Caddy base** (`FROM caddy:2.11.3-builder` and `FROM caddy:2.11.3`) — tracked by Dependabot.
- **caddy-l4 plugin** (`xcaddy build --with github.com/mholt/caddy-l4@v0.1.1`) — tracked by [`.github/workflows/poll-caddy-l4-releases.yml`](../../../.github/workflows/poll-caddy-l4-releases.yml) (weekly Mondays).

Both mechanisms auto-PR when a new version is available. To apply:

1. Review the PR's release notes (Caddy changelog or caddy-l4 changelog).
2. Merge.
3. The `build-heimdall-caddy-img.yml` workflow builds the new image and pushes to GHCR.
4. From the workstation: `bash Heimdall/scripts/deploy.sh --no-secrets` — Heimdall pulls the new tag and recreates the caddy container.

---

## Re-onboard Periphery (when the trust state breaks)

If Periphery shows offline in Komodo and the journal shows handshake errors:

1. SSH to Heimdall.
2. Blank the existing onboarding key:

   ```bash
   sudo sed -i 's/^onboarding_key = ".*"/onboarding_key = ""/' /etc/komodo/periphery.config.toml
   ```

3. From the workstation: `bash Heimdall/scripts/deploy.sh --no-secrets`. The `onboard-periphery.sh` step detects the empty key and re-mints a fresh one.

If Komodo Core has a stale Server record from a prior onboarding, delete it in the Komodo UI first (Servers → heimdall → Delete) so the re-onboard creates a clean record.

---

## Add a new LAN device to the Caddy CA trust

Per device, once. See [`runbooks/trust-store-distribution.md`](../runbooks/trust-store-distribution.md) for per-OS commands.

Quick path on Linux clients:

```bash
curl -fsSL http://192.168.10.4/ca.crt -o /tmp/caddy-internal-ca.crt
sudo cp /tmp/caddy-internal-ca.crt /usr/local/share/ca-certificates/heimdall-caddy-internal-ca.crt
sudo update-ca-certificates
```

Verify: `curl -fsS https://komodo.lab` returns Komodo HTML with no `-k` flag needed.

---

## Take a backup snapshot manually

```bash
ssh owner@192.168.10.4 'bash /opt/Homelab/Heimdall/scripts/backup.sh'
```

Dry-run first if you're not sure what it'll do:
```bash
ssh owner@192.168.10.4 'bash /opt/Homelab/Heimdall/scripts/backup.sh --dry-run'
```

Snapshots land at `akasha:/mnt/Media-Storage/Infra-Storage/heimdall-backups/<DATE>/`, retention 30 days. The script handles pruning automatically.

---

## Restore a single file from a backup snapshot

```bash
LATEST=$(ssh truenas_admin@192.168.10.247 \
    'ls -1 /mnt/Media-Storage/Infra-Storage/heimdall-backups/ | sort | tail -1')
echo "Latest snapshot: $LATEST"

rsync -av "truenas_admin@192.168.10.247:/mnt/Media-Storage/Infra-Storage/heimdall-backups/${LATEST}/caddy/data/caddy/pki/authorities/local/root.crt" \
    /tmp/restored-root.crt
```

For full directory restore (e.g., recovering Mongo state), see Scenario A step 4 in [03 — Deployment](03-deployment.md#step-4--restore-only-when-rebuilding-not-for-initial-install).

---

## Find a secret

All Heimdall secrets are encrypted under `Heimdall/secrets/`:

```bash
# On workstation:
ls Heimdall/secrets/
# env.sops.env
# technitium-admin-pw.sops

# View all env vars:
sops --decrypt Heimdall/secrets/env.sops.env

# Find one:
sops --decrypt Heimdall/secrets/env.sops.env | grep -E '^KOMODO_INIT_ADMIN_'

# Get Technitium password:
sops --decrypt --input-type binary --output-type binary Heimdall/secrets/technitium-admin-pw.sops
```

Decryption uses your age private key at `~/.config/sops/age/keys.txt`. No clear-text secret is committed to git.

See [05 — Secrets](05-secrets.md) for the full SOPS workflow.

## Next

- **[Secrets workflow](05-secrets.md)** — generate, rotate, recover.
- **[Troubleshooting](06-troubleshooting.md)** — when an operation goes wrong.
