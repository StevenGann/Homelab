# Cloudflare Tunnel — public access to web services

Exposes a **narrow allowlist** of web services to the internet with no open inbound
ports and no exposed home IP. Design: [`docs/design/sso-plan.md`](../../docs/design/sso-plan.md).
Full bring-up: [`docs/runbooks/sso-bring-up.md`](../docs/runbooks/sso-bring-up.md) §7.

## Files

| File | Role |
|------|------|
| `config.yml` | Ingress map (hostname → LAN origin). IaC source of truth. |
| `docker-compose.yml` | `cloudflared` (outbound-only). Separate Compose project, started by `scripts/deploy.sh`. |
| `credentials.json` | Tunnel secret — **never committed raw**; SOPS-encrypted at `Heimdall/secrets/cloudflared-credentials.sops`, shipped at deploy. |

## Public hostname map (web — through this tunnel)

| Hostname | → Origin | App auth |
|----------|----------|----------|
| `auth.stevengann.com` | Caddy `:443` → Authentik | Authentik (the IdP itself) |
| `seerr.stevengann.com` | `192.168.10.54` | Sign in with Jellyfin (LDAP-backed) |
| `homarr.stevengann.com` | `192.168.10.53` | Authentik OIDC |
| `cloud.stevengann.com` | `192.168.10.87` (Nextcloud v34) | Authentik OIDC (`user_oidc`) |
| `komga.stevengann.com` | `192.168.10.82:25600` | Authentik OIDC |
| `romm.stevengann.com` | `192.168.10.78:8080` | Authentik OIDC |
| `beszel.stevengann.com` | `192.168.10.68:8090` | Authentik OIDC (PocketBase OAuth2) |
| `musicseerr.stevengann.com` | `192.168.10.74:8688` | Sign in with Jellyfin (inherits) |
| `panel.stevengann.com` | `192.168.10.69` (Pterodactyl) | ⚠️ **its own login — no SSO.** Enable Pterodactyl 2FA. |

**Not exposed, deliberately** (see [`public-access-plan.md`](../../docs/design/public-access-plan.md)):
Navidrome (D-2 — Subsonic auth can't use the IdP), Immich (D-3 — may be
retired), and **Uptime-Kuma** (v1.23.16 has no OIDC; exposing the admin UI would
gate the whole monitoring config behind one password).

**`jf.stevengann.com` (Jellyfin) is NOT here** — kept off the tunnel (video / ToS
§2.8) and exposed directly via a dedicated isolated Caddy listener + UCG
port-forward. See the runbook §8 and the Caddyfile "Public Jellyfin" block.

Everything on the tunnel is internet-facing, so each app relies on its own
(Authentik-backed) login. **Do not use Cloudflare Access at all** (D-4): Access in
front of `auth` breaks the OIDC token exchange, and in front of `cloud` it breaks
the Nextcloud sync clients — while on the browser-only apps it just produces a
second, redundant login. Add a Cloudflare **WAF rate-limit rule on `auth`**
instead (e.g. 10 req/10 s per IP on `/flows/*` and `/api/v3/flows/*`).

## Operator setup (one-time — after DNS is on Cloudflare)

```bash
cloudflared tunnel login                      # browser auth to Cloudflare
cloudflared tunnel create heimdall            # prints a UUID + writes ~/.cloudflared/<UUID>.json
# 1) put the UUID into config.yml  (tunnel: <UUID>)
# 2) encrypt the credentials json into the repo:
cd Heimdall && sops --encrypt --input-type json --output-type json \
    ~/.cloudflared/<UUID>.json > secrets/cloudflared-credentials.sops
# 3) point the public hostnames at the tunnel (creates the proxied CNAMEs):
for h in auth seerr homarr cloud komga romm beszel musicseerr panel; do
  cloudflared tunnel route dns heimdall $h.stevengann.com
done
# 4) deploy:
./scripts/deploy.sh
```

## The SECOND tunnel — `cloudflared-stream`

Subwave gets its **own** tunnel ([`Heimdall/cloudflared-stream/`](../cloudflared-stream/)),
not another hostname here. It streams continuous audio, which is the same CDN-terms
exposure that kept Jellyfin off Cloudflare entirely. **This** tunnel carries
`auth.stevengann.com` — if a terms action ever landed on the tunnel serving the
stream and it were the same tunnel, every OIDC login in the lab would stop at
once. Separating them bounds the blast radius to Subwave.

```bash
cloudflared tunnel create heimdall-stream          # a SECOND tunnel
# UUID -> Heimdall/cloudflared-stream/config.yml (tunnel:)
cd Heimdall && sops --encrypt --input-type json --output-type json \
    ~/.cloudflared/<STREAM-UUID>.json > secrets/cloudflared-stream-credentials.sops
cloudflared tunnel route dns heimdall-stream subwave.stevengann.com
./scripts/deploy.sh
```

Killing it stops the radio and nothing else:
`docker compose -p cloudflared-stream down`.

## Exposed directly (NOT via this tunnel)

These use a **grey-cloud (DNS-only) record + a UCG port-forward** (home IP exposed,
scoped to the listed port):

- **`jf.stevengann.com` (Jellyfin)** → a grey-cloud **`A`** record maintained by
  **ddns-updater via the Cloudflare API** (D-5 — the old NoIP `monolith.ddns.net`
  CNAME chain is dead: the container is unhealthy and the name holds a stale IP).
  UCG forward WAN TCP `443` → `192.168.10.4:7443` (the isolated Caddy block, real
  LE cert → Akasha `:30013`). Kept off the tunnel to avoid Cloudflare ToS §2.8 and
  so a ToS action can't take the identity plane down with it.
- **Game servers — DEFERRED (2026-09-05).** Both Minecraft and Space Engineers ran
  on Thoth, which is powered off, so there is nothing to expose. The `25565`
  nftables rules were removed rather than left open to nothing. Re-add the rules,
  the DNS records and the UCG forwards when Thoth returns.

To avoid home-IP exposure you'd need paid Cloudflare Spectrum or a VPS relay (e.g.
playit.gg) — out of scope. See the runbook §8.
