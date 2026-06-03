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

- **UI:** Directory → Users → Create; add to `friends-family` (+ `media-users` for
  Jellyfin); set a password or send an invite.
- **IaC:** drop a user blueprint under `Heimdall/authentik/blueprints/` (see the
  [authentik README](../../authentik/README.md)) and redeploy. Note blueprints
  don't prune users — disable/delete in the UI.

## 7. Public web exposure — Cloudflare Tunnel

One-time, after you've decided to go live (stack + ingress map:
[`Heimdall/cloudflared/`](../../cloudflared/)).

1. **Move stevengann.com DNS to Cloudflare** (registrar stays Namecheap):
   - Create a free Cloudflare account → Add site `stevengann.com` → let it import
     existing records. **Verify the GitHub Pages records imported** (apex `A` →
     185.199.108–111.153, `www` CNAME → `stevengann.github.io`); set those to **DNS
     only / grey-cloud** so GitHub keeps serving the blog + its own cert.
   - At Namecheap → Domain → Nameservers → **Custom DNS** → enter the two Cloudflare
     nameservers. Propagates in minutes–hours; the blog keeps working throughout.
2. **Create the tunnel + routes + credentials** — see
   [`Heimdall/cloudflared/README.md`](../../cloudflared/README.md) "Operator setup":
   `cloudflared tunnel login` → `create heimdall` → put the UUID in `config.yml` →
   SOPS-encrypt the JSON to `secrets/cloudflared-credentials.sops` →
   `tunnel route dns` for `auth jf seerr music homarr`.
3. **Deploy:** `cd Heimdall && ./scripts/deploy.sh` (brings up the tunnel once the
   credentials exist).
4. **Switch Authentik's default brand/issuer host to public** if needed and confirm
   `https://jf.stevengann.com` + `https://auth.stevengann.com` load with a valid
   public cert from off-network.

WAF/hardening (optional): add a Cloudflare rate-limit rule on `auth.stevengann.com`.
Never put Cloudflare Access in front of `auth`, `jf`, or `music`.

## 8. Direct exposure (NOT via the tunnel) — Jellyfin + game servers

All use a **grey-cloud (DNS-only) record → home IP + a UCG port-forward**. Each is
reachable from the WAN, so each relies on its own auth.

**Jellyfin** (kept off the tunnel by choice — heavy video, Cloudflare ToS §2.8):

- DNS: `jf.stevengann.com` → CNAME `monolith.ddns.net`, **DNS only (grey-cloud)**.
- UCG: port-forward **WAN TCP 443 → `192.168.10.4:7443`**. That `:7443` Caddy block
  serves **only** `jf.stevengann.com` (attack-surface isolation — the `.lab` admin
  UIs and `auth` live on `:443`, which is NOT WAN-forwarded, so they stay private).
- TLS: Caddy auto-issues a real Let's Encrypt cert via TLS-ALPN-01 (validates on
  external `:443` → `:7443`). The cert won't issue until the port-forward + DNS are
  live, so set those first; then `./scripts/deploy.sh` (the Caddyfile change restarts
  Caddy). Verify `https://jf.stevengann.com` from off-network shows a valid cert.
- Auth is Jellyfin's own LDAP-backed login. If it's ever attacked/DDoS'd, options
  then: move it behind the tunnel, add fail2ban on Akasha, or a VPS relay.

**Game servers** (raw TCP/UDP — can't use the HTTP tunnel):

- `mc.stevengann.com` / `se.stevengann.com` → CNAME `monolith.ddns.net` (grey-cloud).
- UCG: **Minecraft TCP 25565**; **Space Engineers UDP 27016** (confirm against the
  egg) → the server's host:port (Pterodactyl allocation). Optional Minecraft `SRV`
  record so players omit the port.

To avoid home-IP exposure entirely: paid Cloudflare Spectrum or a VPS relay
(e.g. playit.gg) — out of scope.

## Rollback

```bash
cd /opt/Homelab/Heimdall/authentik  && docker compose -p authentik  down   # keeps volumes
cd /opt/Homelab/Heimdall/cloudflared && docker compose -p cloudflared down  # stops public access
```
No app is forced through SSO: Jellyfin keeps local accounts until you enable the
plugin; Homarr keeps `credentials`. Removing the stack reverts cleanly.
