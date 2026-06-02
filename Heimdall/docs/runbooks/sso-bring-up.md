# Runbook — SSO bring-up (Authentik)

Stand up the identity plane and connect the first friend. Plan/rationale:
[`docs/design/sso-plan.md`](../../../docs/design/sso-plan.md). Stack files:
[`Heimdall/authentik/`](../../authentik/).

Everything below the secrets is IaC: `git push` + `scripts/deploy.sh` reconciles
Authentik, its blueprints, Caddy, and DNS. The hands-on bits are one credential
(the LDAP outpost token), the **Jellyfin LDAP plugin on Akasha** (Jellyfin lives
outside this repo), and remote access via the **existing VPN** (out of scope here —
SSO is transport-agnostic; just confirm friends get LAN routing + `.lab` DNS).

## 0. Preconditions

- The secrets already exist (generated 2026-06-02) in `Heimdall/secrets/env.sops.env`:
  `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_PG_PASS`, `AUTHENTIK_BOOTSTRAP_PASSWORD/TOKEN`,
  `AUTHENTIK_HOMARR_CLIENT_ID/SECRET`. One is a placeholder you fill in §2:
  `AUTHENTIK_LDAP_OUTPOST_TOKEN`.
- Heimdall reachable at `owner@192.168.10.4`; `sops` + the age key on the workstation.
- The existing VPN routes `192.168.10.0/24` to friends and hands them Technitium for
  `.lab` DNS (so `auth.lab` / `jellyfin.lab` resolve). Verify before onboarding.

## 1. First deploy — Authentik

```bash
cd Heimdall && ./scripts/deploy.sh
```

This ships `.env`, pulls/starts the Authentik project, and the worker applies the
blueprints (groups, Homarr OIDC, Nextcloud placeholder, LDAP provider + outpost).

Verify + first login:

```bash
# akadmin password:
cd Heimdall && sops -d secrets/env.sops.env | grep AUTHENTIK_BOOTSTRAP_PASSWORD
```

- Browse `https://auth.lab` (trust Caddy's internal CA, or `http://heimdall.lab/ca.crt`).
- Log in as `akadmin`. Confirm under **Applications**: Homarr, Nextcloud, LDAP;
  under **Directory → Groups**: `friends-family`, `media-users`.
- If a blueprint errored, check **System → Tasks** / `docker compose -p authentik logs worker`.

## 2. LDAP outpost token (one-time paste)

1. **Applications → Outposts → LDAP → View Token** (or edit the outpost). Copy it.
2. Put it in the env and redeploy:
   ```bash
   cd Heimdall && sops secrets/env.sops.env   # set AUTHENTIK_LDAP_OUTPOST_TOKEN=<token>
   ./scripts/deploy.sh
   ```
3. The `ldap` container now authenticates. Allow LDAP through Heimdall's firewall
   if needed (LAN only):
   ```
   # Heimdall/hostconf/nftables.conf — permit 389/636 from 192.168.10.0/24
   ```

## 3. Jellyfin LDAP (on Akasha — manual, outside IaC)

Jellyfin runs on TrueNAS (`192.168.10.247:30013`); configure in its web UI:

1. Dashboard → Plugins → Catalog → install **LDAP Authentication** → restart.
2. Configure:
   - **LDAP Server**: `192.168.10.4`  **Port**: `389` (StartTLS/636 optional)
   - **Base DN**: `DC=lab,DC=homelab`  ·  **User search base**: `ou=users,DC=lab,DC=homelab`
   - **User search filter**: `(&(objectClass=user)(cn={username}))`
   - **Bind DN**: a dedicated Authentik service account (create one and add it to
     `media-users`), or enable per-user bind.
   - **Username attribute**: `cn`  ·  test with a `media-users` member.
3. Set "Enable user creation" so first LDAP login provisions the Jellyfin user.

**Seerr** then just works via its "Sign in with Jellyfin" — no separate config.

## 4. Remote access (two tiers)

Both tiers authenticate against the same Authentik.

**Admin tier — UniFi WiFiman/Teleport VPN.** Trusted friends, full LAN, `.lab`.
Verify a test client can:
- reach the LAN: `curl -k https://192.168.10.4` and `https://192.168.10.247:30013`
  (Jellyfin) succeed.
- resolve `.lab`: `auth.lab`, `jellyfin.lab` resolve. Teleport hands out the gateway
  resolver by default — if `.lab` doesn't resolve, point the VPN/gateway DNS at
  Technitium (`192.168.10.4`) or hand admins the IPs.

**Public tier — Cloudflare Tunnel** (`Heimdall/cloudflared/`, scaffolded separately).
cloudflared dials Caddy; only the allowlisted public hostnames (`jellyfin.<domain>`,
`seerr.<domain>`, `navidrome.<domain>`, `nextcloud.<domain>`, `auth.<domain>`) are
routable. Cloudflare presents the public cert; apps use their own Authentik-backed
login. **Do not** put Cloudflare Access in front of Jellyfin/Navidrome (native
clients can't pass its token). See that stack's README for tunnel-token + DNS steps.

## 5. Homarr ↔ Authentik TLS trust (the one OIDC gotcha)

Homarr (in k8s) validates the issuer `https://auth.lab/...`, signed by Caddy's
internal CA — which Node won't trust by default. Pick one:

- **A — trust the CA (keeps `.lab`):** fetch the root and mount it:
  ```bash
  curl -s http://heimdall.lab/ca.crt -o caddy-internal-ca.crt
  kubectl -n media create configmap homarr-ca --from-file=ca.crt=caddy-internal-ca.crt
  ```
  then add to the Homarr deployment: a `homarr-ca` configMap volume at
  `/certs/ca.crt` and `NODE_EXTRA_CA_CERTS=/certs/ca.crt`. (Left out of git
  because `root.crt` is generated at Caddy runtime, not committed.)
- **B — public issuer (simplest if Homarr is on the public tier):** set
  `AUTH_OIDC_ISSUER` to `https://auth.<domain>/application/o/homarr/`. Cloudflare's
  edge already serves a publicly-trusted cert for it, so Homarr validates with no CA
  mount and no Caddy change. Recommended once the tunnel is up.

Then on Homarr's login page choose **Authentik**; first OIDC login auto-creates the
Homarr user, role from the `groups` claim.

## 6. Provision friends (replaces the bot)

- **UI:** Directory → Users → Create; add to `friends-family` (+ `media-users` for
  Jellyfin); set a password or send an invite.
- **IaC:** drop a user blueprint under `Heimdall/authentik/blueprints/` (see the
  [authentik README](../../authentik/README.md)) and redeploy. Note blueprints
  don't prune users — disable/delete in the UI.

## Rollback

```bash
cd /opt/Homelab/Heimdall/authentik && docker compose -p authentik down   # keeps volumes
```
No app is forced through SSO: Jellyfin keeps local accounts until you enable the
plugin; Homarr keeps `credentials`. Removing the stack reverts cleanly.
