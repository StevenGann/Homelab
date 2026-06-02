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

### 2.1 Two layers (keep both — they answer different questions)

- **The existing VPN (network identity)** — *"is this device allowed on the
  network?"* Friends connect through the operator's already-deployed VPN and reach
  services on the LAN. Nothing is exposed to the WAN. The VPN choice is out of scope
  for this plan; the only two things SSO needs from it are: (a) the VPN routes the
  `192.168.10.0/24` LAN to clients, and (b) clients resolve `.lab` names via
  Technitium (so `auth.lab`, `jellyfin.lab`, etc. work). Confirm both for whatever
  VPN is in use.
- **Authentik (app identity)** — *"which user is this, and what may they see?"* The
  VPN cannot give each friend their own Jellyfin library, per-user Seerr requests,
  etc. Authentik is the one directory all apps authenticate against — independent of
  the transport.

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
2. **TLS trust.** Caddy's internal CA throws cert warnings on friends' devices and
   you can't realistically install your root CA on someone's iPhone/Apple TV. Two
   escapes: distribute nothing and front the shared services with a **publicly-trusted
   cert** (a real domain + **Let's Encrypt via DNS-01**), or accept the warnings for
   browser apps and rely on each native client's own trust. NB: the Heimdall Caddy
   image (`Heimdall/caddy/image/Dockerfile`) currently bundles **only `caddy-l4`** —
   the `caddy-dns/cloudflare` (or other DNS) plugin is **not** built in, so the
   LE-DNS-01 path needs an image rebuild first. Do **not** ship the internal CA to
   friends. (Jellyfin's own client validates its own endpoint, so Jellyfin is the
   least affected.)
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

- **Navidrome disposition** — web-only share vs. separate password vs. Jellyfin-for-music.
- **TLS strategy** — accept internal-CA warnings vs. real domain + LE DNS-01 (needs a
  Caddy image rebuild for a DNS plugin, and a registered domain).
- **VPN ↔ SSO assumptions** — confirm the existing VPN routes `192.168.10.0/24` to
  friends and that they get `.lab` DNS from Technitium (else `auth.lab`/app names
  won't resolve over the VPN).
- **How far to extend forward-auth** over admin apps — uniform login wall, or leave
  admin apps on their current per-app auth (LAN-only already gates them).
- **Authentik vs. lighter Authelia+LLDAP** — locked to Authentik for the
  self-service/invite UX; revisit only if Heimdall resource pressure becomes real.

---

## 8. As-built IaC boundary (2026-06-02 scaffold)

Three bands, mapped to what's committed:

**✅ Committed IaC (deploys mechanically via `git push` + `deploy.sh`/Flux):**
- `Heimdall/authentik/` — compose stack (server/worker/postgres/redis/LDAP outpost)
  + blueprints (groups, Homarr OIDC, Nextcloud placeholder, LDAP provider+outpost).
- `Heimdall/scripts/deploy.sh` — brings up the Authentik project.
- `Heimdall/caddy/Caddyfile` (`auth.lab`) + `Heimdall/scripts/seed-zones.sh` (`auth.lab` A).
- `Hyperion/k8s/apps/media/20-extras/homarr/` — OIDC env + client creds in the SOPS secret.
- Machine secrets generated + SOPS-encrypted into `Heimdall/secrets/env.sops.env`.

**🟡 One external value, then it deploys (placeholder committed):**
- `AUTHENTIK_LDAP_OUTPOST_TOKEN` — read from the Authentik UI after first apply.

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
