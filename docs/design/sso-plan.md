# SSO for Friend/Family-Facing Services — Implementation Plan

> **Status:** Identity-plane IaC SCAFFOLDED 2026-06-02 (Authentik + blueprints +
> Homarr OIDC + Caddy/DNS wiring committed; not yet deployed). Bring-up:
> [`Heimdall/docs/runbooks/sso-bring-up.md`](../../Heimdall/docs/runbooks/sso-bring-up.md).
> Locked operator decisions (2026-06-01 → 2026-06-02): **IdP = Authentik; IdP
> placement = Heimdall. Remote access = the operator's existing VPN** (NOT public
> exposure; Tailscale was considered and dropped 2026-06-02 — a VPN is already in
> place). SSO is transport-agnostic: the identity plane does not depend on which VPN.
>
> Goal: retire the legacy "janky Discord bot" that created accounts and synced one
> password into each app's separate user database. Replace it with a single
> identity directory plus the minimum integration glue each app actually supports.
>
> The Authentik pieces live under `Heimdall/` (compose + `scripts/deploy.sh` pattern,
> same as Caddy/Technitium/Komodo); per-app OIDC client config lands in the app's
> existing `Hyperion/k8s/` manifest tree.

---

## 1. Problem & current state

**The bot exists because there is no shared directory.** Every app today holds its
own local user DB or API key; the bot brute-forced "one account everywhere" by
writing the same password into each. There is **no IdP** in the repo (no
Authentik/Authelia/Keycloak/LLDAP), and everything is **LAN-only**: MetalLB
LoadBalancers on `192.168.10.x`, `.lab` names from Technitium, TLS from Caddy's
**internal CA**. No public domain, no Let's Encrypt-over-WAN, no VPN tracked in-repo.
The UCG already forwards `:443` to Heimdall but it is unused.

**The hard constraint that shapes everything below:** Jellyfin and Navidrome have
native TV/mobile clients that speak their **own username/password protocol** and
cannot carry an OIDC cookie or a forward-auth header. A pure "OIDC + forward-auth"
design works for browsers and locks those clients out. So no single mechanism
covers the shareable set — we need three, behind one directory.

---

## 2. Architecture — two identity layers, three integration patterns

### 2.1 Layers — one identity directory, two transports

**Network/transport (two tiers — answer "can this device reach the service?"):**

- **Admin tier — UniFi WiFiman/Teleport VPN (WireGuard).** Trusted friends with
  admin intent. Full LAN, `.lab` names, internal-CA TLS (admins can trust the CA).
  Needs: the VPN routes `192.168.10.0/24` and clients resolve `.lab` via Technitium
  (verify — Teleport hands out the gateway resolver by default).
- **Public tier — Cloudflare Tunnel → cloudflared → Caddy → service.** Broader
  friends/family. A **narrow allowlist** of public services only (Jellyfin, Seerr,
  Navidrome, Nextcloud, + a few). Cloudflare's edge presents a **publicly-trusted
  cert** for `*.<yourdomain>` — no CA distribution to friends. cloudflared dials the
  origin (Caddy) over the LAN; only the listed hostnames are routable.

**App identity (one layer — answers "who is this, and what may they see?"):**

- **Authentik.** Neither transport gives each friend their own Jellyfin library /
  per-user Seerr requests. Authentik is the one directory all apps authenticate
  against, reachable on **both** `auth.lab` (admin tier) and `auth.<yourdomain>`
  (public tier, via the tunnel). Transport-independent.

**Hard rule for the public tier:** never put Cloudflare Access / forward-auth in
front of **Jellyfin or Navidrome** — their native clients can't carry an Access
cookie/token (same constraint as forward-auth). Expose them directly; the app's own
Authentik-backed login is the gate. Browser-only apps (Seerr/Nextcloud/Homarr)
already have SSO, so Access there is redundant.

### 2.2 Three integration patterns

| # | Pattern | Authentik feature | Covers | Why this and not OIDC/forward-auth |
|---|---------|-------------------|--------|-------------------------------------|
| 1 | **LDAP** | LDAP outpost | Jellyfin (→ Seerr via "Sign in with Jellyfin") | Native TV/mobile clients only speak username/password; LDAP is the only thing they can use. **This is the actual bot replacement.** |
| 2 | **OIDC** | OAuth2/OIDC provider | Homarr, Nextcloud (future) | Clean redirect-based SSO; use wherever the app supports it natively. |
| 3 | **Forward-auth** | Proxy provider + Caddy `forward_auth` | web-only apps with weak/no auth you still want gated | Zero app-side config; puts a login wall in front. Browser-only — never in front of native-client apps. |

---

## 3. Per-app disposition matrix

**Share with friends/family:**

| App | Where | Pattern | Notes |
|-----|-------|---------|-------|
| **Jellyfin** | Akasha `:30013` (NodePort, not k8s) | **LDAP** (jellyfin-plugin-ldapauth) | Highest-value win. Verify login works in the **mobile/TV app**, not just the web UI. |
| **Seerr / Jellyseerr** | k8s `media`, `192.168.10.54` | inherits Jellyfin | Uses "Sign in with Jellyfin" → rides on the LDAP-backed Jellyfin accounts for free. |
| **Navidrome** | k8s `media`, `192.168.10.66` | **EXCEPTION** | No LDAP; Subsonic API (DSub/Symfonium) only speaks password. Web UI can do reverse-proxy header auth, but mobile stays a Navidrome-local password regardless of IdP. Decide: web-only share / separate password / push friends to Jellyfin for music. |
| **Homarr** | k8s `media`, `192.168.10.53` | **OIDC** | Native OIDC. Good friend landing page; host the "getting started" links here. |
| **Nextcloud** | *not yet deployed* | **OIDC** (user_oidc) | Excellent OIDC/SAML support. Wire when deployed. |

**Admin-only — never share (LAN-only or forward-auth at most):**
all *arr (Sonarr/Radarr/Lidarr/Prowlarr), qBittorrent, Cleanuparr, Tdarr, Trailarr,
SuggestArr, Kapowarr, Youtarr, Headlamp, Komodo, Technitium, Beszel, Speedtest,
Hermes, Pterodactyl admin. These keep their current auth; gate with forward-auth
only if you want a uniform login wall.

---

## 4. Placement & ownership

**Authentik on Heimdall** (recommended), via the `Heimdall/` docker-compose +
`scripts/deploy.sh` pattern, alongside Caddy/Technitium/Komodo:

- Identity plane sits with the edge proxy (Caddy) + DNS (Technitium) — all on one
  host. Forward-auth and TLS integration are local.
- Keeps Authentik's Postgres + Redis + worker **off the Pi workers** still mid
  NixOS pivot.
- Trade-off: outside the Flux GitOps flow (consistent with how the other Heimdall
  services are managed). Per-app **OIDC client** config still lands in each app's
  `Hyperion/k8s/` manifest (SOPS-encrypted client secret, `data`/`stringData` only —
  see the Flux SOPS encryption-form rule).

Secrets: Authentik bootstrap token + per-app OIDC client secrets via SOPS, same as
the existing Heimdall/Hyperion conventions.

---

## 5. Gotchas to design around (VPN path)

1. **TV / streaming-box clients on the VPN — the real rough edge.** Whatever the
   VPN, a phone/tablet/laptop is easy; a TV is case-by-case — many smart TVs can't
   run a VPN client at all. If the VPN does whole-LAN routing from a gateway/router
   the friend connects through, the TV is covered without an on-TV client; if it's a
   per-device client VPN, TVs that can't run it are stuck. Set expectations either way.
2. **TLS trust — solved per tier, no Caddy change.** Public tier: **Cloudflare's
   edge terminates TLS** with a real cert for `*.<yourdomain>`, so friends never see
   the internal CA and the OIDC issuer is a public hostname (no `NODE_EXTRA_CA_CERTS`
   needed for anything exposed publicly). cloudflared dials the Caddy origin over the
   LAN — Caddy can keep serving `tls internal` to it (cloudflared
   `originRequest.noTLSVerify: true`), so **no Caddy image rebuild / DNS plugin is
   required**. Admin tier: `.lab` keeps the internal CA; admins can trust it. The CA
   is never shipped to public friends.
3. **Two-step onboarding.** Each friend now has connect-the-VPN **and**
   create-the-Authentik-account. Self-service enrollment is **deferred** in the
   as-built scaffold: it realistically needs SMTP (email verification), which isn't
   set up. Until then provision friends operator-side — via the Authentik UI or a
   user blueprint (accounts-as-IaC; see the Authentik README) — which already
   replaces the bot. Add the enrollment flow + SMTP later.

---

## 6. Phased rollout

1. **Authentik on Heimdall** (compose + deploy.sh). Create operator + one test friend.
2. **LDAP outpost → Jellyfin LDAP plugin.** Verify a friend logs into the Jellyfin
   **mobile app**. (Biggest single win; retires most of the bot.)
3. **Confirm Seerr** inherits via "Sign in with Jellyfin."
4. **Remote access** — confirm a test friend on the existing VPN can reach
   `jellyfin.lab` / `auth.lab` (LAN routed + `.lab` DNS resolves). Decide TLS (CA
   warning vs. public cert) per §5.2.
5. **OIDC for Homarr** (landing page) and **Nextcloud** when deployed.
6. **Navidrome** — pick its disposition (§3). Don't let it block the rest.

Each phase is independently useful; phase 2 alone justifies the project.

---

## 7. Open decisions (resolve before building)

- **Public domain — RESOLVED:** `stevengann.com` (Namecheap registrar, DNS moving to
  Cloudflare). Apex stays on GitHub Pages (blog); apps on subdomains. See the
  hostname map in §8.
- **Public allowlist — RESOLVED (web):** Jellyfin, Seerr, Navidrome, Homarr, Nextcloud
  (when deployed) via the tunnel; `mc`/`se` game servers via DDNS+port-forward (§8).
- **Navidrome disposition** — web-only share vs. separate password vs. Jellyfin-for-music.
- **Teleport `.lab` DNS** — confirm WiFiman/Teleport VPN clients resolve `.lab` via
  Technitium (else admins can't hit `auth.lab`/app names; hand out IPs or set VPN DNS).
- **How far to extend forward-auth** over admin apps — uniform login wall, or leave
  admin apps on their current per-app auth (LAN-only already gates them). Public-tier
  native-client apps (Jellyfin/Navidrome) must stay OFF forward-auth/Cloudflare Access.
- **Authentik vs. lighter Authelia+LLDAP** — locked to Authentik for the
  self-service/invite UX; revisit only if Heimdall resource pressure becomes real.

---

## 8. As-built IaC boundary (2026-06-02 scaffold)

Three bands, mapped to what's committed:

**Public hostname map (`stevengann.com`):**

| Host | Transport | → Origin |
|------|-----------|----------|
| `auth` | Cloudflare Tunnel | Caddy → Authentik (required for public OIDC) |
| `seerr` | Cloudflare Tunnel | `192.168.10.54` |
| `music` | Cloudflare Tunnel | `192.168.10.66` (Navidrome) |
| `homarr` | Cloudflare Tunnel | `192.168.10.53` |
| `cloud` | Cloudflare Tunnel | Nextcloud (commented until deployed) |
| `jf` | **DDNS + UCG fwd → isolated Caddy `:7443`** (off-tunnel: video / ToS §2.8) | Akasha `:30013`, real LE cert |
| `mc` / `se` | **DDNS CNAME + UCG port-forward** (HTTP-only tunnel can't carry games) | Minecraft TCP 25565 / Space Engineers UDP 27016 |

Apex `stevengann.com` + `www` stay on GitHub Pages (blog), grey-cloud. Only the WAN
`:443→:7443` (Jellyfin) and the game ports are forwarded; `.lab` + `auth` are not
WAN-reachable (tunnel-only / LAN-only).

**✅ Committed IaC (deploys mechanically via `git push` + `deploy.sh`/Flux):**
- `Heimdall/authentik/` — compose stack (server/worker/postgres/redis/LDAP outpost)
  + blueprints (groups, Homarr OIDC, Nextcloud placeholder, LDAP provider+outpost).
- `Heimdall/cloudflared/` — tunnel compose + `config.yml` ingress (web allowlist).
- `Heimdall/scripts/deploy.sh` — brings up Authentik + (when keyed) the tunnel.
- `Heimdall/caddy/Caddyfile` (`auth.lab` + `auth.stevengann.com`) +
  `Heimdall/scripts/seed-zones.sh` (`auth.lab` A).
- `Hyperion/k8s/apps/media/20-extras/homarr/` — OIDC env (public issuer) + client
  creds in the SOPS secret.
- Machine secrets generated + SOPS-encrypted into `Heimdall/secrets/env.sops.env`.

**🟡 External values, then it deploys (operator-supplied):**
- `AUTHENTIK_LDAP_OUTPOST_TOKEN` — read from the Authentik UI after first apply.
- `secrets/cloudflared-credentials.sops` + the tunnel UUID in `config.yml` — from
  `cloudflared tunnel create` once stevengann.com DNS is on Cloudflare.
- Cloudflare account + nameserver move at Namecheap; UCG port-forwards for `mc`/`se`.

**❌ Not IaC-able in this repo (hands-on):**
- **Jellyfin LDAP plugin install + config — on Akasha (TrueNAS), outside the tree.**
  The single highest-value consumer; configured in Jellyfin's UI. Runbook §3.
- Homarr↔Authentik internal-CA trust (or a publicly-trusted issuer cert) — runbook §5.
- Self-service enrollment flow + SMTP (deferred; provision via UI/blueprint meanwhile).
- Remote access via the existing VPN: confirm LAN routing + `.lab` DNS for friends.
- Creating/inviting actual friends.

---

## 9. References

- App inventory & exposure: `docs/homelab-user-guide.md`, `Hyperion/k8s/apps/**`,
  `Heimdall/scripts/seed-zones.sh` (`.lab` records).
- Heimdall service pattern: `Heimdall/docker-compose.yml`, `Heimdall/caddy/Caddyfile`
  (internal CA; image bundles **only `caddy-l4`** — no `caddy-dns/cloudflare`),
  `Heimdall/scripts/deploy.sh`.
- Flux SOPS encryption form (encrypt `data`/`stringData` only): `Hyperion/k8s/README.md`.
- This plan supersedes the LAN-only shared-password convention for *public-facing*
  apps; admin-UI password convention is unchanged.
