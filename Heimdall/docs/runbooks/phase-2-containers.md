# Phase 2 — Container deployment

> **Goal:** bring up the Heimdall Compose stack (mongo + Komodo Core + Technitium + Caddy), onboard Periphery into Komodo Core, and seed the minimum-viable Technitium zone. Phase 2 ends with an **end-to-end self-test gate**: from a LAN client with the Caddy internal-CA root trusted, `https://komodo.lab` loads the Komodo UI. Until that gate passes, Phase 2 is not complete.
>
> **One command does all of this**: `bash Heimdall/scripts/deploy.sh` on the workstation. Sections 1–4 below describe what that script does, in case you need to do them manually or understand what's happening.

## Prerequisites

- Phase 1 complete (see [`phase-1-host.md`](phase-1-host.md)).
- Workstation has the SOPS age private key at `~/.config/sops/age/keys.txt`.
- `sops` installed on workstation (`curl … | sudo tee /usr/local/bin/sops; chmod +x` — see [generate-secrets.sh](../../scripts/generate-secrets.sh) prereq check).
- Passwordless SSH from workstation to `owner@192.168.10.4` (`ssh-copy-id owner@192.168.10.4`).
- Passwordless sudo for `owner` on Heimdall (`echo "owner ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/owner-nopasswd && sudo chmod 0440 /etc/sudoers.d/owner-nopasswd`) — required if you want automation tools (like deploy.sh) to run sudo without a tty.

## The one-command path

```bash
cd ~/GitHub/Homelab
bash Heimdall/scripts/deploy.sh
```

What it does, in order:

1. Decrypts `Heimdall/secrets/env.sops.env` on the workstation, pipes the cleartext over SSH to `/opt/Homelab/Heimdall/.env` on Heimdall.
2. Decrypts `Heimdall/secrets/technitium-admin-pw.sops` (binary), ships to `/opt/Homelab/Heimdall/secrets/technitium-admin-pw`.
3. `ssh owner@192.168.10.4` and on Heimdall:
   - `git pull` (latest compose, scripts, configs)
   - Preflight: confirms `owner` is in the `docker` group; adds via `sudo usermod -aG docker owner` if not.
   - `docker compose pull && docker compose up -d`
   - Waits for Komodo Core HTTP API on `:9120` (up to 60s).
   - Runs `onboard-periphery.sh` (see §3 below).
   - Waits for Technitium API on `:5380` (up to 60s).
   - Runs `seed-zones.sh` (see §4 below).

Flags: `--no-secrets` (skip the decrypt/ship if `.env` already shipped), `--no-deploy` (ship secrets only), `--dry-run`, `--host owner@<ip>` (override target).

The whole sequence is idempotent. Re-running on an already-deployed Heimdall is safe.

If something fails partway, the script exits non-zero with the specific error. Sections 1–4 below cover what to do manually for each step.

## What each step does (for understanding / manual recovery)

### 1. Decrypt secrets

Secrets live SOPS-encrypted in `Heimdall/secrets/`:

- `Heimdall/secrets/env.sops.env` — Komodo + Mongo env vars (dotenv format).
- `Heimdall/secrets/technitium-admin-pw.sops` — single-line Technitium admin password (binary).

Both are committed to the repo. The age private key on the workstation decrypts them. Heimdall never has the age key.

First-time generation of the encrypted files:

```bash
# On the workstation:
bash Heimdall/scripts/generate-secrets.sh
git add Heimdall/secrets/env.sops.env Heimdall/secrets/technitium-admin-pw.sops
git commit -m 'heimdall: scaffold encrypted secrets'
git push
```

Manual decrypt + ship (what `deploy.sh` does internally):

```bash
sops --decrypt Heimdall/secrets/env.sops.env | \
    ssh owner@192.168.10.4 'tee /opt/Homelab/Heimdall/.env > /dev/null && chmod 600 /opt/Homelab/Heimdall/.env'

sops --decrypt --input-type binary --output-type binary Heimdall/secrets/technitium-admin-pw.sops | \
    ssh owner@192.168.10.4 'tee /opt/Homelab/Heimdall/secrets/technitium-admin-pw > /dev/null && chmod 600 /opt/Homelab/Heimdall/secrets/technitium-admin-pw'
```

Both decrypted files are `.gitignore`d.

### 2. Pull and start containers

```bash
cd /opt/Homelab/Heimdall
docker compose pull
docker compose up -d
```

Expected: mongo, komodo-core, technitium, caddy all start. First start of Technitium creates `/etc/dns/dns.config` inside the container (bind-mounted to `Heimdall/technitium/config/`). First start of Caddy generates the internal-CA root at `caddy/data/caddy/pki/authorities/local/root.crt`. Komodo Core creates its admin user in MongoDB using `KOMODO_INIT_ADMIN_*` from `.env`.

### 3. Onboard Periphery into Komodo Core

```bash
bash /opt/Homelab/Heimdall/scripts/onboard-periphery.sh
```

What the script does (the **empirical reality** as of Komodo v2.2.0, after verification on the running Heimdall):

1. **Login.** `POST http://127.0.0.1:9120/auth/login` with `{"type":"LoginLocalUser","params":{"username":"owner","password":"…"}}`. Response shape is **adjacently-tagged**: `{"type":"Jwt","data":{"jwt":"…"}}` — the JWT is at `.data.jwt`.
2. **Mint onboarding key.** `POST /write` with `{"type":"CreateOnboardingKey","params":{"name":"heimdall","expires":0,…}}`. Response is `{"private_key":"…","created":{…}}` — the `private_key` is the one-time TOFU credential to put in Periphery's TOML.
3. **Write to Periphery's TOML** at `/etc/komodo/periphery.config.toml`:
   - `onboarding_key = "<the-private-key>"`
   - `core_addresses = ["http://127.0.0.1:9120"]` — **outbound mode**. Without this, Periphery is in inbound mode (listening for Core to dial it), and onboarding never completes because nothing tells Core where to find Periphery. With `core_addresses` set, Periphery dials Core, presents the onboarding key, and the Server record is auto-created in Core with `connect_as` as the server name (default: `heimdall`).
4. **Restart Periphery.** `sudo systemctl restart periphery.service`. On startup, Periphery reads `onboarding_key` + `core_addresses`, dials Core, completes the Noise-protocol handshake, exchanges its public key for the onboarding key, and registers the Server record.
5. **Poll until ready.** Polls `POST /read {"type":"ListServers","params":{"query":{}}}` until the server reports `state: "Ok"`, max 60s.

Script is idempotent: detects an existing non-empty `onboarding_key` line in the TOML and exits without changes. To force re-onboarding, blank that line manually and re-run.

### 4. Seed the Technitium zone

```bash
bash /opt/Homelab/Heimdall/scripts/seed-zones.sh
```

What it does:

1. **Login to Technitium.** `GET http://127.0.0.1:5380/api/user/login?user=admin&pass=…` (query-string params, not JSON). Response includes `{"token":"…"}`.
2. **Create the `lab` primary zone** if absent: `POST /api/zones/create?token=…&zone=lab&type=Primary`.
3. **For each record in `RECORDS=()` array at the top of the script**, GET the existing records via `/api/zones/records/get`, add via `/api/zones/records/add` if absent.

Additive-only contract: never deletes, never updates existing records. Phase 2 seed = just `komodo.lab → 192.168.10.4`. Phase 3 grows the list.

### 5. Trust the Caddy internal-CA root on a LAN client

For step 6 to work, the LAN client needs to trust Caddy's internal-CA root.

```bash
# Fetch the root cert (LAN-only via Heimdall's :80 LAN listener)
curl -o caddy-internal-ca.crt http://192.168.10.4/ca.crt

# Trust per OS — see trust-store-distribution.md
```

### 6. End-to-end self-test (Phase 2 acceptance gate)

From a LAN workstation with the CA root trusted:

```bash
curl -fsS https://komodo.lab | head
# Expected: HTML containing <title>Komodo</title>; status 200.
```

Heimdall-self-contained variant (no LAN-client precondition):

```bash
ssh owner@192.168.10.4 \
    'curl -fsS --resolve komodo.lab:443:192.168.10.4 \
         --cacert /opt/Homelab/Heimdall/caddy/data/caddy/pki/authorities/local/root.crt \
         https://komodo.lab | head'
```

If both return Komodo's HTML, Phase 2 is complete.

## Phase 2 acceptance checklist

- [ ] `docker compose ps` shows mongo, komodo-core, technitium, caddy all `Up`.
- [ ] `systemctl is-active periphery.service` returns `active`.
- [ ] Komodo UI at `http://192.168.10.4:9120` (or `https://komodo.lab` via Caddy) shows `heimdall` server with state `Ok`.
- [ ] `dig @192.168.10.4 google.com` returns an answer (Technitium forwarders working).
- [ ] `dig @192.168.10.4 doubleclick.net` returns a blocked response.
- [ ] `dig @192.168.10.4 komodo.lab` returns `192.168.10.4`.
- [ ] `curl -sk http://192.168.10.4/ca.crt` returns the Caddy internal-CA root.
- [ ] End-to-end self-test (§6) passes from both LAN client AND from Heimdall.

## Troubleshooting (with lessons from actual install)

- **`docker compose pull` 404s on the Caddy image.** The image is at `ghcr.io/stevengann/homelab-heimdall-caddy:v2.11.3-l4-0.1.1`. If GHCR returns 404, the CI workflow hasn't published it yet. Check `.github/workflows/build-heimdall-caddy-img.yml` runs in the GitHub UI.

- **`Permission denied while trying to connect to docker API`** during `docker compose pull`. `owner` isn't in the `docker` group. `deploy.sh` auto-detects and fixes this; manually: `ssh -t owner@192.168.10.4 'sudo usermod -aG docker owner'`. Takes effect on the next SSH session.

- **Komodo Core in crash-loop with "Server selection timeout: mongo:27017"**: the daemon's bridge networking is broken — usually after a docker daemon restart with `live-restore: true`, OR after `nft flush ruleset` cleared Docker's NAT/MASQUERADE rules. Fix: `docker compose down && docker compose up -d` to fully recreate the network. All persistent state is bind-mounted, so this is non-destructive.

- **Komodo Core port :9120 not bound on host (`docker compose ps` shows no PORTS column)**: same root cause as above — Docker's iptables/nftables NAT rules are missing. `systemctl restart docker` re-installs them; if that doesn't help, the down/up cycle from the previous bullet does.

- **`onboard-periphery.sh` succeeds but Periphery never reaches `Ok` state**: Periphery is configured in inbound mode (`core_addresses = []`) and Core doesn't know to dial it. The current script writes `core_addresses` alongside `onboarding_key` to put Periphery in outbound mode — confirm by `sudo grep core_addresses /etc/komodo/periphery.config.toml` on Heimdall.

- **`https://komodo.lab` returns SSL warning on the LAN client.** The internal-CA root isn't in the client's trust store. See [`trust-store-distribution.md`](trust-store-distribution.md).

- **Edited Caddyfile but Caddy still serves the old config.** Docker's file-bind-mount (`/opt/.../Caddyfile:/etc/caddy/Caddyfile`) holds the file's inode at container-start time. `git pull` replaces the file via rename, leaving the bind mount pointing at the OLD inode. `docker compose up -d` doesn't fix this (it only restarts containers whose image / spec changed). Fix: `docker compose restart caddy`. `deploy.sh` does this automatically when it detects Caddyfile changed in the pull. Same pattern applies to any file-bind-mounted config — `periphery.config.toml`, `AdGuardHome.yaml`-style configs, etc.

## Next

Proceed to [`phase-3-configuration.md`](phase-3-configuration.md) for ongoing operational work (adding routes, records, more services).
