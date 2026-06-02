# Authentik — homelab SSO identity provider

Single user directory for friend/family-facing apps. Replaces the legacy
password-sync bot. Design rationale: [`docs/design/sso-plan.md`](../../docs/design/sso-plan.md).
Bring-up + day-2: [`docs/runbooks/sso-bring-up.md`](../docs/runbooks/sso-bring-up.md).

## What's here

| File | Role |
|------|------|
| `docker-compose.yml` | postgres + redis + server + worker + LDAP outpost. Separate Compose project under `/opt/Homelab/Heimdall/authentik/`, started by `scripts/deploy.sh`. |
| `blueprints/00-groups.yaml` | `friends-family` + `media-users` groups. |
| `blueprints/10-provider-homarr.yaml` | OIDC provider + app for Homarr (client creds via `!Env`, shared with the Homarr k8s Secret). |
| `blueprints/20-provider-nextcloud.yaml` | OIDC placeholder for Nextcloud (not yet deployed). |
| `blueprints/30-provider-ldap.yaml` | LDAP provider + outpost — the Jellyfin / native-client path. |

Blueprints are **declarative config-as-code**: the worker auto-discovers every
`*.yaml` under `/blueprints/custom` and applies it. Edit, `git push`, redeploy —
no click-ops. Re-applying is idempotent (entries are matched by `identifiers`).

## Integration patterns (one directory, three mechanisms)

- **OIDC** → Homarr, Nextcloud (apps that speak it natively).
- **LDAP** → Jellyfin (native TV/mobile clients can only do username/password).
- **Forward-auth** (Caddy `forward_auth` → an Authentik proxy provider) → any
  browser-only app you later want gated. Not wired yet; add a proxy provider
  blueprint + a Caddyfile snippet when needed.

## Accounts as IaC (optional — replaces the bot directly)

Provision a friend declaratively by adding a blueprint like:

```yaml
version: 1
metadata:
  name: friend-jane
  labels: { blueprints.goauthentik.io/instantiate: "true" }
entries:
  - model: authentik_core.user
    identifiers: { username: jane }
    attrs:
      name: Jane Q
      email: jane@example.com
      groups:
        - !Find [authentik_core.group, [name, friends-family]]
        - !Find [authentik_core.group, [name, media-users]]
      path: users
```

Set their first password in the UI (or send an invite). Removing the file does
**not** delete the user (blueprints don't prune `authentik_core.user`); disable
or delete in the UI. Prefer the UI for anything with PII you'd rather not commit.

## Secrets (all in `Heimdall/secrets/env.sops.env`)

Generated (machine): `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_PG_PASS`,
`AUTHENTIK_BOOTSTRAP_PASSWORD` (akadmin first login), `AUTHENTIK_BOOTSTRAP_TOKEN`,
`AUTHENTIK_HOMARR_CLIENT_ID/SECRET`.
One-time operator paste: `AUTHENTIK_LDAP_OUTPOST_TOKEN` (from the UI after the
LDAP outpost is created).

```bash
cd Heimdall && sops -d secrets/env.sops.env | grep AUTHENTIK_BOOTSTRAP_PASSWORD
```

## Pin

`ghcr.io/goauthentik/{server,ldap}:2026.5.2` (latest stable, 2026-06-02). Bump in
lockstep; pin by digest after first pull, matching the repo convention.
