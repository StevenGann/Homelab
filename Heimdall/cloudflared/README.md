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

**Not exposed, deliberately** (see [`public-access-plan.md`](../../docs/design/public-access-plan.md)):
`music` / Navidrome (D-2 — Subsonic auth can't use the IdP) and Immich (D-3 —
may be retired).

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
for h in auth seerr homarr cloud; do cloudflared tunnel route dns heimdall $h.stevengann.com; done
# 4) deploy:
./scripts/deploy.sh
```

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
