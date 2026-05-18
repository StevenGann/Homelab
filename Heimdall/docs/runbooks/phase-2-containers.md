# Phase 2 — Container deployment

> **Goal:** bring up the Heimdall Compose stack, onboard Periphery into Komodo
> Core, and verify the stack end-to-end. Phase 2 ends with an **end-to-end
> self-test gate**: from a LAN client with the Caddy internal-CA root trusted,
> `https://komodo.lab` loads the Komodo UI. Until that gate passes, Phase 2 is
> not complete.

## Prerequisites

- Phase 1 complete (see [`phase-1-host.md`](phase-1-host.md)).
- Workstation has the SOPS age private key at `~/.config/sops/age/keys.txt`.

## Steps

### 1. Decrypt secrets

Secrets live SOPS-encrypted in `Heimdall/secrets/` and committed to the repo:

- `Heimdall/secrets/env.sops.env` — Komodo + Mongo env vars.
- `Heimdall/secrets/technitium-admin-pw.sops` — single-line Technitium admin password.

**Decrypt on the workstation, ship cleartext to Heimdall via SSH.** This keeps the age private key off Heimdall (smaller blast radius if Heimdall is ever compromised). Heimdall never needs `sops` installed.

First-time setup of the encrypted files (one-time, if the files don't exist yet):

```bash
# On the workstation:
bash Heimdall/scripts/generate-secrets.sh
git add Heimdall/secrets/env.sops.env Heimdall/secrets/technitium-admin-pw.sops
git commit -m 'heimdall: scaffold encrypted secrets'
git push
```

Then deploy:

```bash
# On Heimdall — pull the new commit so the encrypted files are present locally:
sudo git -C /opt/Homelab pull

# On the workstation — decrypt and ship to Heimdall over SSH:
sops --decrypt Heimdall/secrets/env.sops.env | \
    ssh owner@192.168.10.4 'sudo tee /opt/Homelab/Heimdall/.env > /dev/null && sudo chmod 600 /opt/Homelab/Heimdall/.env'

sops --decrypt --input-type binary --output-type binary Heimdall/secrets/technitium-admin-pw.sops | \
    ssh owner@192.168.10.4 'sudo tee /opt/Homelab/Heimdall/secrets/technitium-admin-pw > /dev/null && sudo chmod 600 /opt/Homelab/Heimdall/secrets/technitium-admin-pw'
```

Both decrypted files are `.gitignore`d on the Heimdall side.

> If the operator's age key is provisioned on Heimdall (alternative pattern; larger blast radius), the decrypt can run there directly: `SOPS_AGE_KEY_FILE=... sops --decrypt /opt/Homelab/Heimdall/secrets/env.sops.env > /opt/Homelab/Heimdall/.env`. The workstation-decrypts-and-ships pattern above is recommended.

### 2. Pull and start

```bash
cd /opt/Homelab/Heimdall
docker compose pull
docker compose up -d
```

Expected: mongo, komodo-core, technitium, caddy all start. First start of Technitium will create `/etc/dns/dns.config` inside the container (bind-mounted to `Heimdall/technitium/config/`) using the env vars. First start of Caddy will generate the internal-CA root at `caddy/data/caddy/pki/authorities/local/root.crt`. Komodo Core will create its admin user in MongoDB.

### 3. Onboard Periphery into Komodo Core

```bash
bash /opt/Homelab/Heimdall/scripts/onboard-periphery.sh
```

The script:

1. Logs in to Komodo Core's HTTP API at `http://127.0.0.1:9120` using the admin credentials from `.env`.
2. Calls `CreateOnboardingKey` to mint a one-time TOFU credential.
3. Writes the credential into `/etc/komodo/periphery.config.toml` as `onboarding_key = "..."`.
4. Restarts `periphery.service`.
5. Polls Komodo Core's `ListServers` endpoint until the server `heimdall` reports `Ok` / `Connected` state, or times out after 60s.

On success the script exits 0. On timeout it warns with diagnostic pointers. The script is idempotent — if the TOML already has an `onboarding_key` set, it exits without changes.

### 4. Seed the minimum-viable Technitium zone

```bash
bash /opt/Homelab/Heimdall/scripts/seed-zones.sh
```

For Phase 2 the script seeds exactly one record: `komodo.lab → 192.168.10.4`. This unlocks the end-to-end self-test in step 6. Phase 3 expands the record set.

The script is additive-only (creates missing records, never deletes). See [`phase-3-configuration.md`](phase-3-configuration.md) for the full contract.

### 5. Trust the Caddy internal-CA root on a LAN client

The end-to-end test in step 6 runs from a LAN workstation. That workstation needs to trust Caddy's internal-CA root. Fetch it:

```bash
curl -o caddy-internal-ca.crt http://192.168.10.4/ca.crt
```

The :80 LAN-only `file_server` block in the Caddyfile serves this exactly once
(or as many times as you want; it's idempotent). Then trust it per OS — see
[`trust-store-distribution.md`](trust-store-distribution.md).

> The :80 route is **LAN-only** (nftables enforces source-restriction to
> `192.168.10.0/24`). It is NOT WAN-forwarded from UCG.

### 6. End-to-end self-test (Phase 2 acceptance gate)

From a LAN workstation with the CA root trusted:

```bash
curl -fsS https://komodo.lab | head
# Expected: HTML response with <title>Komodo</title> or similar; status 200.
```

For a Heimdall-self-contained variant that does not depend on the LAN client (per
the punch-list M6 fix), run from Heimdall itself:

```bash
curl -fsS --resolve komodo.lab:443:192.168.10.4 \
     --cacert /opt/Homelab/Heimdall/caddy/data/caddy/pki/authorities/local/root.crt \
     https://komodo.lab | head
```

If both forms return Komodo's HTML, Phase 2 is complete.

## Phase 2 acceptance checklist

Confirm each:

- [ ] `docker compose ps` shows mongo, komodo-core, technitium, caddy all `running (healthy)`.
- [ ] `systemctl is-active periphery.service` returns `active`.
- [ ] Komodo UI at `http://192.168.10.4:9120` (or `https://komodo.lab`) shows `heimdall` as a connected server.
- [ ] `dig @192.168.10.4 google.com` returns an answer (Technitium forwarders working).
- [ ] `dig @192.168.10.4 doubleclick.net` returns a blocked response.
- [ ] `dig @192.168.10.4 komodo.lab` returns `192.168.10.4`.
- [ ] `curl -sk http://192.168.10.4/ca.crt` returns the Caddy internal-CA root.
- [ ] End-to-end self-test above passes (both forms).

## Troubleshooting

- **`docker compose pull` fails on the Caddy image.** The image is at `ghcr.io/stevengann/homelab-heimdall-caddy:v2.11.3-l4-0.1.1`. If GHCR returns 404, the CI build hasn't published it yet. Check `.github/workflows/build-heimdall-caddy-img.yml` runs in the GitHub UI.
- **Technitium 502/blank UI.** The container takes ~10s to initialize. Wait, then `docker compose logs technitium`.
- **`onboard-periphery.sh` times out.** Check `journalctl -u periphery.service -n 50` for handshake errors. The most common cause is the `PERIPHERY_ADDR` scheme not matching Periphery's `ssl_enabled` setting in `/etc/komodo/periphery.config.toml`.
- **`https://komodo.lab` returns SSL warnings on the LAN client.** The internal-CA root is not yet in the LAN client's trust store. See [`trust-store-distribution.md`](trust-store-distribution.md).

## Next

Proceed to [`phase-3-configuration.md`](phase-3-configuration.md) for ongoing operational work (adding services, records, etc.).
