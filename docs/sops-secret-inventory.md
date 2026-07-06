# SOPS secret inventory & recoverability assessment

**Created:** 2026-07-06
**Trigger:** Workstation migration on 2026-07-06 revealed the **operator age
private key is lost**. The only age key on the migration backup USB was the
*pre-rotation* key (`age1hmxzj58…`, created 2026-04-06). Commit `8f7803a`
("Heimdall SOPS setup", 2026-05-17) rotated the operator recipient to
`age1u8tfm7scg35csrnam9ntnppne5728593yw7fk3p9sz7ecl06dpgs958ncm`, whose private
half exists on no known medium. See `docs/runbooks/disaster-recovery.md` §0 —
this is the "single recovery root" it warned about.

This document answers two questions:

1. **What is SOPS-encrypted in this repo, and what does each item hold?**
2. **Which items can be recovered from live running systems** (so we can avoid a
   disruptive regenerate-everything), and which — if any — must be regenerated.

> **Bottom line:** With the cluster and hosts still running, **essentially every
> secret is recoverable without the lost operator key.** All 25 k8s secrets are
> independently decryptable by the in-cluster Flux age key (not lost) *and* are
> live as applied Secrets. The NixOS secrets are decryptable by the per-node keys
> (live on the Pis). The remaining operator-only secrets are all materialized in
> a running service or host and can be read back. **No item requires a truly
> disruptive regeneration**; the only "regenerate" candidates are two low-stakes
> session/OTA keys that cost nothing to rotate.

---

## Recipient legend

Every ciphertext lists (in cleartext) the age public keys that can decrypt it.
That recipient set is what determines recoverability, because the *operator*
private key is gone but other recipients' private halves are not.

| Tag | Recipient key | Private half location | Lost? |
|-----|---------------|-----------------------|-------|
| **OP** | `age1u8tfm7s…` | operator workstation `~/.config/sops/age/keys.txt` | **YES — lost** |
| **FLX** | `age1wjvfq7kt5z04q3r04k9l2exjxuql0y8n0tq7qxylrjs5vn8ss5pqkv9x59` | in-cluster Secret `flux-system/sops-age` | **No** — live in cluster |
| **NODE×n** | 10 per-node keys (`age1u44…`, `age1c8p…`, …) | each Pi's NVMe `/var/lib/sops-nix/key.txt` | **No** — live on nodes |

**Live-system reachability verified 2026-07-06 from the new workstation:**

| Host | Addr | Status |
|------|------|--------|
| k3s API (Heimdall control-plane container) | `192.168.10.4:6443` | **OPEN** |
| Heimdall SSH | `192.168.10.4:22` | closed (use Komodo UI / host console) |
| Thoth SSH | `192.168.10.144:22` | **OPEN** |
| Akasha SSH | `192.168.10.247:22` | **OPEN** |
| Pi node (alpha) SSH | `192.168.10.101:22` | **OPEN** |

---

## Recovery tiers

- **Tier A — decrypt with a non-lost key (zero service disruption).** A second
  recipient (Flux key or node keys) still holds the plaintext-decryption
  capability. Just run `sops -d` with that key.
- **Tier B — read the plaintext back from a live host/container.** OP-only
  ciphertext (can't be decrypted), but the value is materialized in a running
  service — read it from the container env, on-disk decrypted file, or app DB.
- **Tier C — must regenerate.** Neither the ciphertext nor any live system yields
  the value. *(In this inventory: effectively none; two low-stakes keys are
  cheap to rotate if desired.)*

---

## 1 + 2. Full inventory with recovery path

### Tier A — k8s app/infra secrets (25 files) · recipients **FLX + OP**

All under `Hyperion/k8s/`, reconciled by Flux. **Two independent recovery
paths, both non-disruptive:**

- **Path 1 (decrypt):** export the Flux key and decrypt the file directly —
  `kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' | base64 -d > flux-age.txt`
  then `SOPS_AGE_KEY_FILE=flux-age.txt sops -d <file>`.
- **Path 2 (read live Secret):** the decrypted Secret is already applied —
  `kubectl -n <ns> get secret <name> -o jsonpath='{.data.<field>}' | base64 -d`.

| File (under `Hyperion/k8s/`) | Namespace | Secret name | Fields |
|---|---|---|---|
| `apps/archisteamfarm/secret.sops.yaml` | archisteamfarm | *(bootstrap config)* | `ASF.json`, `IPC.config`, `Main_Bot.json`, `ASF.db`, `Main_Bot.db`, `SteamTokenDumper.cache` |
| `apps/caldera/secret.sops.yaml` | caldera | `caldera-secrets` | `CALDERA_API_KEYS`, `CALDERA_GITHUB_TOKEN`, `CALDERA_WEBHOOK_SECRET` |
| `infrastructure/agent-caldera/secret.sops.yaml` | agent-caldera | `agent-caldera-secrets` | `CALDERA_API_KEYS`, `CALDERA_GITHUB_TOKEN`, `CALDERA_WEBHOOK_SECRET` |
| `apps/hermes/dashboard-auth.sops.yaml` | hermes | `hermes-dashboard-auth` | `.htpasswd`, `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD` |
| `apps/hermes/deepseek.sops.yaml` | hermes | `hermes-deepseek` | `DEEPSEEK_API_KEY` |
| `apps/jeeves/dashboard-auth.sops.yaml` | jeeves | `jeeves-dashboard-auth` | `.htpasswd`, `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD` |
| `apps/jeeves/deepseek.sops.yaml` | jeeves | `jeeves-deepseek` | `DEEPSEEK_API_KEY` |
| `apps/jeeves/shared.sops.yaml` | jeeves | `jeeves-shared` | `GITHUB_TOKEN`, `HASS_TOKEN` |
| `apps/jellystat/secret.sops.yaml` | jellystat | `jellystat-secret` | `POSTGRES_PASSWORD`, `JWT_SECRET` |
| `apps/media/10-core/lidarr/secret.sops.yaml` | media | `lidarr-secret` | `LIDARR__AUTH__APIKEY` |
| `apps/media/10-core/prowlarr/secret.sops.yaml` | media | `prowlarr-secret` | `PROWLARR__AUTH__APIKEY` |
| `apps/media/10-core/radarr/secret.sops.yaml` | media | `radarr-secret` | `RADARR__AUTH__APIKEY` |
| `apps/media/10-core/sonarr/secret.sops.yaml` | media | `sonarr-secret` | `SONARR__AUTH__APIKEY` |
| `apps/media/10-core/qbittorrent/secret.sops.yaml` | media | `qbittorrent-vpn` | `OPENVPN_USER`, `OPENVPN_PASSWORD`, `WIREGUARD_PRIVATE_KEY`, `WEBUI_PASSWORD` |
| `apps/media/10-core/qbittorrent2/secret.sops.yaml` | media | `qbittorrent2-vpn` | *(same 4 fields)* |
| `apps/media/10-core/qbittorrent3/secret.sops.yaml` | media | `qbittorrent3-vpn` | *(same 4 fields)* |
| `apps/media/20-extras/homarr/secret.sops.yaml` | media | `homarr-secret` | `SECRET_ENCRYPTION_KEY`, `AUTH_OIDC_CLIENT_ID`, `AUTH_OIDC_CLIENT_SECRET` |
| `apps/media/20-extras/seerr/secret.sops.yaml` | media | `seerr-secret` | `API_KEY` |
| `apps/media/20-extras/youtarr/secret.sops.yaml` | media | `youtarr-secret` | `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE`, `MARIADB_ROOT_PASSWORD` |
| `apps/monolithbot/secret.sops.yaml` | monolithbot | `monolithbot-config` | `config.json` |
| `apps/pterodactyl/secret.sops.yaml` | pterodactyl | `pterodactyl-secret` | `APP_KEY`, `DB_PASSWORD`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE`, `MARIADB_ROOT_PASSWORD` |
| `apps/speedtest-tracker/secret.sops.yaml` | speedtest-tracker | `speedtest-secret` | `APP_KEY` |

> ⚠️ **Caveat on Path 1 (Flux key):** this depends on the `flux-system/sops-age`
> Secret still existing in the cluster. **Verify first** —
> `kubectl -n flux-system get secret sops-age`. If it is ever lost too, Path 2
> (reading the already-applied Secrets) still recovers everything, since Flux has
> already decrypted and applied them.

### Tier A — NixOS cluster secret · recipients **OP + 10 NODE keys**

| File | Holds | Recovery |
|---|---|---|
| `Hyperion/nixos/secrets/common.yaml` | `k3s-token` (the cluster join token) | Decrypt with **any** node key: `ssh <node> 'sudo cat /var/lib/sops-nix/key.txt'` → `SOPS_AGE_KEY_FILE=<that> sops -d common.yaml`. The token is also live on the running control plane and every joined node. Non-disruptive. |

### Tier A — per-node identity archives · recipient **OP only** (but content is live)

| Files | Holds | Recovery |
|---|---|---|
| `Hyperion/nixos/node-keys/hyperion-{alpha,beta,gamma,delta,epsilon,zeta,eta,theta,iota,kappa}.tar.age` | each node's sops **age private key** + its **SSH host keys** | The `.tar.age` themselves are OP-encrypted (unreadable now), **but the contents are live on each Pi**: `/var/lib/sops-nix/key.txt` and `/etc/ssh/ssh_host_*`. Re-harvest over SSH and rebuild the archives against a new operator key. Non-disruptive. |

### Tier B — Heimdall edge-stack secrets · recipient **OP only**

Ciphertext is unrecoverable, but every value is materialized on the running
Heimdall host / containers. **Access note:** Heimdall `:22` is currently closed —
use the **Komodo UI**, the host console, or re-open SSH to read these.

| File | Holds | Live source to read from |
|---|---|---|
| `Heimdall/secrets/env.sops.env` | Komodo (`KOMODO_DATABASE_USERNAME/PASSWORD`, `KOMODO_INIT_ADMIN_USERNAME/PASSWORD`, `KOMODO_JWT_SECRET`, `KOMODO_WEBHOOK_SECRET`) + Authentik (`AUTHENTIK_SECRET_KEY`, `AUTHENTIK_PG_PASS`, `AUTHENTIK_BOOTSTRAP_PASSWORD`, `AUTHENTIK_BOOTSTRAP_TOKEN`, `AUTHENTIK_HOMARR_CLIENT_ID/SECRET`, `AUTHENTIK_LDAP_OUTPOST_TOKEN`) | Decrypted `.env` on the Heimdall host (written by `Heimdall/scripts/deploy.sh`), the running Komodo/Authentik container env (`docker inspect`), and the Authentik Postgres DB / admin UI. |
| `Heimdall/secrets/k3s-control-plane.sops.env` | `K3S_TOKEN` | Same token as `common.yaml` (Tier A) — also in the control-plane container env and on every node. Trivially recovered. |
| `Heimdall/secrets/technitium-admin-pw.sops` | Technitium DNS admin password | Set in the running Technitium instance; known to operator or resettable from the Technitium admin console. |
| `Heimdall/secrets/ddns-config.json.sops` | ddns-updater provider config + API token | Live in the running `ddns-updater` container config on Heimdall. |

### Tier B — Thoth secrets · recipient **OP only**

Thoth `:22` is **OPEN** — read directly.

| File | Holds | Live source |
|---|---|---|
| `Thoth/secrets/env.sops.env` | `OPENWEBUI_SECRET` (Open-WebUI session signing key) | Running open-webui container env on Thoth. *Low stakes:* if lost, only invalidates existing sessions → **Tier C-trivial** (regenerate freely). |
| `Thoth/secrets/wings-config.sops.yaml` | Pterodactyl Wings `token_id` + `token` (daemon↔panel pairing) | Thoth `/etc/pterodactyl/config.yml`, **and** the Pterodactyl panel DB (itself the Tier-A `pterodactyl` k8s app). |

### Tier B — Sensors (ESPHome) · recipient **OP only**

| File | Holds | Live source / disposition |
|---|---|---|
| `Sensors/Temperature/secrets.sops.yaml` | `wifi_ssid`, `wifi_password`, `fallback_ap_password`, `api_encryption_key`, `ota_password`, `mqtt_broker`, `mqtt_username`, `mqtt_password` | WiFi + MQTT creds are known to operator; **MQTT creds are duplicated in cleartext** in `mosquitto/secret.yaml` (see finding below). ESPHome `api_encryption_key`/`ota_password` are baked into flashed firmware and **regenerate trivially** on next re-flash → **Tier C-trivial**. |

---

## Recovery summary

| Tier | Items | Disruption | Action |
|------|-------|-----------|--------|
| **A** (decrypt w/ non-lost key) | 25 k8s + `common.yaml` + 10 node archives | none | `sops -d` with Flux key / node key; re-harvest node identities over SSH |
| **B** (read from live host) | 4 Heimdall + 2 Thoth + 1 Sensors | none (needs host access) | read container env / on-disk `.env` / app DB |
| **C** (regenerate) | *(none mandatory)* — only `OPENWEBUI_SECRET` + ESPHome `api/ota` keys, if you choose | trivial | rotate at leisure |

**The whole set is recoverable while systems are up.** The recommended sequence
is captured as an actionable runbook in
**`docs/runbooks/key-backup-and-recovery.md`** (companion to this doc), which also
mints a fresh operator age key and re-encrypts every secret to it —
**re-establishing the SOPS workflow without changing a single password.**

---

## Related finding: plaintext secrets committed to git

Two secret files are **tracked in git as cleartext** (not SOPS, not sealed):

- `Hyperion/k8s/apps/nextcloud/mariadb-secret.yaml` — `MYSQL_ROOT_PASSWORD`,
  `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`
- `Hyperion/k8s/infrastructure/mosquitto/secret.yaml` — mosquitto `passwd`
  (bcrypt) for user `mosquitto`

These are an independent exposure (public-repo GitOps). They should be migrated
into SOPS (`encrypted_regex: ^(data|stringData)$`, recipients OP-new + FLX) and
the plaintext history considered for rotation. Tracked as a follow-up, not part
of the key-loss recovery.
