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
| `seerr.stevengann.com` | `192.168.10.54` | Sign in with Jellyfin |
| `music.stevengann.com` | `192.168.10.66` | Navidrome |
| `homarr.stevengann.com` | `192.168.10.53` | Authentik OIDC |
| `cloud.stevengann.com` | *(Nextcloud, when deployed)* | Authentik OIDC |

**`jf.stevengann.com` (Jellyfin) is NOT here** — kept off the tunnel (video / ToS
§2.8) and exposed directly via a dedicated isolated Caddy listener + UCG
port-forward. See the runbook §8 and the Caddyfile "Public Jellyfin" block.

Everything on the tunnel is internet-facing, so each app relies on its own
(Authentik-backed) login. **Never** put Cloudflare Access in front of `music` — its
native clients can't pass an Access token (and Access in front of `auth` would break
the OIDC token exchange). Add Cloudflare WAF / rate-limiting on `auth` if you want
extra brute-force protection.

## Operator setup (one-time — after DNS is on Cloudflare)

```bash
cloudflared tunnel login                      # browser auth to Cloudflare
cloudflared tunnel create heimdall            # prints a UUID + writes ~/.cloudflared/<UUID>.json
# 1) put the UUID into config.yml  (tunnel: <UUID>)
# 2) encrypt the credentials json into the repo:
cd Heimdall && sops --encrypt --input-type json --output-type json \
    ~/.cloudflared/<UUID>.json > secrets/cloudflared-credentials.sops
# 3) point the public hostnames at the tunnel (creates the proxied CNAMEs):
for h in auth seerr music homarr; do cloudflared tunnel route dns heimdall $h.stevengann.com; done
# 4) deploy:
./scripts/deploy.sh
```

## Exposed directly (NOT via this tunnel)

These use a **grey-cloud (DNS-only) record + a UCG port-forward** (home IP exposed,
scoped to the listed port):

- **`jf.stevengann.com` (Jellyfin)** → CNAME `monolith.ddns.net` (DNS only) ; UCG
  forward WAN TCP `443` → `192.168.10.4:7443` (the isolated Caddy block, real LE
  cert → Akasha `:30013`). Kept off the tunnel to avoid Cloudflare ToS §2.8.
- **`mc.stevengann.com` (Minecraft)** → CNAME `monolith.ddns.net` (DNS only) ; UCG
  forward TCP `25565` → the Minecraft server's host:port (Pterodactyl allocation).
- **`se.stevengann.com` (Space Engineers)** → CNAME `monolith.ddns.net` (DNS only) ;
  UCG forward UDP `27016` (confirm against the egg) → that server.

To avoid home-IP exposure you'd need paid Cloudflare Spectrum or a VPS relay (e.g.
playit.gg) — out of scope. See the runbook §8.
