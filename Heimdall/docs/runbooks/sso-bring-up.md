# Runbook — SSO bring-up (Authentik)

> **Execution plan:** [`docs/design/public-access-plan.md`](../../../docs/design/public-access-plan.md)
> (2026-09-05). That document owns the sequencing, the decisions (D-1…D-14) and
> the exit tests; this runbook is the hands-on detail for the steps. Where they
> disagree, the plan wins. Changed since this runbook was written: Navidrome and
> Immich are **not** exposed; `cloud` (Nextcloud) **is**; `jf` uses a Cloudflare
> grey-cloud A record via ddns-updater, not the dead NoIP chain; game servers are
> deferred with Thoth.

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
  under **Directory → Groups**: `friends-family` (the only group — it is also
  the LDAP provider's `search_group`, per D-8).
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
     `friends-family`), or enable per-user bind. **Never use `akadmin`.**
   - **Username attribute**: `cn`  ·  test with a `friends-family` member.
3. Set "Enable user creation" so first LDAP login provisions the Jellyfin user.
   LDAP-created users must NOT be administrators.
4. Dashboard → General: enable **login lockout** after N failed attempts. Once
   `jf.stevengann.com` is public this is the only brute-force control on that path.
5. Keep one **local** Jellyfin admin outside LDAP (break-glass, D-13) — a Heimdall
   outage must not lock you out of your own media server.

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

## 5. Enable Homarr OIDC (gated until Authentik is up)

**First, flip the gate.** Homarr ships with `AUTH_PROVIDERS: "credentials"` so the
pushed manifest is a no-op until the IdP exists. Once Authentik + the tunnel are
live and `auth.stevengann.com` resolves, edit
`Hyperion/k8s/apps/media/20-extras/homarr/deployment.yaml` →
`AUTH_PROVIDERS: "credentials,oidc"`, commit, push (Flux applies it). The
`AUTH_OIDC_*` vars are already set.

As-built, Homarr's `AUTH_OIDC_ISSUER` is `https://auth.stevengann.com/...` (the
public Cloudflare hostname). Cloudflare's edge serves a publicly-trusted cert, so
Homarr validates with **no CA mount and no Caddy change** — the old internal-CA
gotcha is gone. This requires the tunnel (§7) to be up and `auth.stevengann.com` to
resolve from the cluster (Technitium forwards public queries upstream).

Fallback only if you ever make Homarr admin-only (`.lab` issuer, internal CA): fetch
`http://heimdall.lab/ca.crt`, mount it as a configMap at `/certs/ca.crt`, and set
`NODE_EXTRA_CA_CERTS=/certs/ca.crt` on the deployment.

Then on Homarr's login page choose **Authentik**; first OIDC login auto-creates the
Homarr user, role from the `groups` claim.

## 6. Provision friends (replaces the bot)

- **UI:** Directory → Users → Create; add to `friends-family` — that one group
  grants both app access and the LDAP bind Jellyfin needs (D-8); set a temporary
  password and have them change it at `https://auth.stevengann.com`.
- **IaC:** drop a user blueprint under `Heimdall/authentik/blueprints/` (see the
  [authentik README](../../authentik/README.md)) and redeploy. Note blueprints
  don't prune users — disable/delete in the UI.

## 7. Public web exposure — Cloudflare Tunnel

One-time, after you've decided to go live (stack + ingress map:
[`Heimdall/cloudflared/`](../../cloudflared/)).

1. ~~**Move stevengann.com DNS to Cloudflare**~~ — **DONE.** Verified 2026-09-05:
   the zone is live on `melnicoff.ns.cloudflare.com` / `opal.ns.cloudflare.com`
   and the apex still serves the GitHub Pages blog. **Do** enable **2FA on the
   Cloudflare account** before going further — it now controls both your DNS and
   your tunnel.
2. **Create the tunnel + routes + credentials** — see
   [`Heimdall/cloudflared/README.md`](../../cloudflared/README.md) "Operator setup":
   `cloudflared tunnel login` → `create heimdall` → put the UUID in `config.yml` →
   SOPS-encrypt the JSON to `secrets/cloudflared-credentials.sops` →
   `tunnel route dns` for `auth seerr homarr cloud` (NOT `jf` — it is direct, and
   NOT `music` — Navidrome is not exposed).
   Route **`auth` first and test it alone** before adding the rest.
3. **Deploy:** `cd Heimdall && ./scripts/deploy.sh` (brings up the tunnel once the
   credentials exist).
4. **Switch Authentik's default brand/issuer host to public** if needed and confirm
   `https://auth.stevengann.com` loads with a valid public cert **from cellular**
   (not just LAN Wi-Fi — that would test nothing).

WAF/hardening: add a Cloudflare **rate-limit rule on `auth.stevengann.com`**
(≈10 req/10 s per IP on `/flows/*` and `/api/v3/flows/*`).
**Do not use Cloudflare Access anywhere** (D-4) — it breaks the OIDC exchange on
`auth`, breaks Nextcloud's sync clients on `cloud`, and is redundant elsewhere.

## 8. Direct exposure (NOT via the tunnel) — Jellyfin + game servers

All use a **grey-cloud (DNS-only) record → home IP + a UCG port-forward**. Each is
reachable from the WAN, so each relies on its own auth.

**Jellyfin** (kept off the tunnel by choice — heavy video, Cloudflare ToS §2.8):

- DNS: `jf.stevengann.com` → a **grey-cloud (DNS-only) `A` record** kept current by
  **ddns-updater via the Cloudflare API** (D-5). Delete the existing *proxied*
  record first — as of 2026-09-05 `jf` is orange-clouded and times out. The old
  NoIP `monolith.ddns.net` chain is dead (container unhealthy, stale IP) and is
  being retired, so do not CNAME to it.
- UCG: port-forward **WAN TCP 443 → `192.168.10.4:7443`**. That `:7443` Caddy block
  serves **only** `jf.stevengann.com` (attack-surface isolation — the `.lab` admin
  UIs and `auth` live on `:443`, which is NOT WAN-forwarded, so they stay private).
- TLS: Caddy auto-issues a real Let's Encrypt cert via TLS-ALPN-01 (validates on
  external `:443` → `:7443`). The cert won't issue until the port-forward + DNS are
  live, so set those first; then `./scripts/deploy.sh` (the Caddyfile change restarts
  Caddy). Verify `https://jf.stevengann.com` from off-network shows a valid cert.
- Auth is Jellyfin's own LDAP-backed login. If it's ever attacked/DDoS'd, options
  then: move it behind the tunnel, add fail2ban on Akasha, or a VPS relay.

**Game servers** (raw TCP/UDP — can't use the HTTP tunnel) — **DEFERRED (D-14).**

Both ran on Thoth, which is powered off, so there is nothing to expose and the
`25565` nftables rules were removed. When Thoth returns: re-add those rules,
create grey-cloud records, and forward **Minecraft TCP 25565** / **Space Engineers
UDP 27016** (confirm against the egg) to the Pterodactyl allocation. Optional
Minecraft `SRV` record so players can omit the port.

To avoid home-IP exposure entirely: paid Cloudflare Spectrum or a VPS relay
(e.g. playit.gg) — out of scope.

## Rollback

```bash
cd /opt/Homelab/Heimdall/authentik  && docker compose -p authentik  down   # keeps volumes
cd /opt/Homelab/Heimdall/cloudflared && docker compose -p cloudflared down  # stops public access
```
No app is forced through SSO: Jellyfin keeps local accounts until you enable the
plugin; Homarr keeps `credentials`. Removing the stack reverts cleanly.
