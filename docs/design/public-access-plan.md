# Public Access Plan — SSO + Cloudflare for friends (no VPN)

> **Status:** PLAN, written 2026-09-05 against a live-verified inventory of every
> host. Supersedes the *sequencing and transport* sections of
> [`sso-plan.md`](sso-plan.md) (§0, §2.1, §6, §8); that document's per-app
> analysis (§2.2, §3) and gotchas (§5) remain valid and are referenced, not
> repeated. Hands-on companion: [`Heimdall/docs/runbooks/sso-bring-up.md`](../../Heimdall/docs/runbooks/sso-bring-up.md).
>
> **Objective:** friends reach a small allowlist of services from the open
> internet with one account each, **no VPN**, and **no client-side CA install**.
> Direct port-forwards are permitted only where nothing else works, and minimised.
>
> **What this changes vs. the June plan:** that plan locked "remote access = the
> operator's VPN; the public tier is deferred". This inverts it — the public tier
> is the deliverable. It also drops Navidrome from the public set, replaces the
> NoIP DDNS chain with Cloudflare's own API, adds Immich as a candidate, and
> re-bases the blocker list on what is actually true today.

---

## 1. Decisions (locked unless marked *decide*)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D-1 | **Jellyfin transport** | **Direct: UCG WAN `:443` → Heimdall `:7443`** (the isolated Caddy listener). *Alternative:* a dedicated second Cloudflare tunnel. | Jellyfin is plain HTTP and *could* use the tunnel; Cloudflare's CDN terms discourage serving video through the proxy, and the tunnel also carries the identity plane — a ToS action there would take `auth` down with it. Direct is the conventional media-server answer and performs better. Cost: **the one port-forward this plan allows.** If you later prefer zero forwards, moving `jf` onto its *own* tunnel is a config-only change. |
| D-2 | **Navidrome** | **Not exposed.** Friends use Jellyfin for music. | Subsonic clients authenticate with `md5(password+salt)` per request — the server must hold a recoverable password and cannot consult LDAP or OIDC. Publicly it would be an unrevocable, MFA-less, IdP-less endpoint. Stays LAN/VPN. |
| D-3 | **Public allowlist** | `auth`, `seerr`, `homarr`, `cloud` (Nextcloud) via tunnel; `jf` direct. **`photos` (Immich) via tunnel — *decide*.** | Everything friend-facing that is browser- or token-based. Immich's mobile app does OAuth in an in-app browser and then uses bearer tokens — tunnel-compatible — but a first phone backup is tens of GB of uploads, which is the "disproportionate large files" pattern. Include if the audience is family who will back up phones; otherwise leave LAN/VPN. |
| D-4 | **Cloudflare Access** | **Not used.** Use a Cloudflare WAF rate-limit rule on `auth` instead. | Native clients (Jellyfin app, Nextcloud sync, Immich app) cannot pass an Access cookie. On browser-only apps it produces a *double* login (Access→Authentik, then app→Authentik/Jellyfin). Revisit only for a browser-only app with weak native auth. |
| D-5 | **DDNS** | **ddns-updater → Cloudflare provider**, updating an `A` record for `jf.stevengann.com` (grey-cloud) directly. Retire the NoIP chain. | The NoIP path is broken today: ddns-updater is `unhealthy` because `stevengann.ddns.net` does not resolve, and `monolith.ddns.net` points at a stale IP. DNS is already on Cloudflare; a scoped API token removes a vendor and a CNAME hop. |
| D-6 | **TLS for `jf`** | Let's Encrypt via **TLS-ALPN-01** through the forward (as designed). *Optional later:* DNS-01 with `caddy-dns/cloudflare`. | Works without a Caddy image rebuild. DNS-01 removes the "cert can't issue until the forward is live" ordering constraint and is a one-line Dockerfile change if wanted. |
| D-7 | **Split-horizon DNS** | **No.** LAN clients resolve `*.stevengann.com` through Cloudflare like everyone else. | One issuer URL, one cert chain, nothing to distribute. In-cluster apps (Homarr) validate tokens via the tunnel hairpin — already how the scaffold is wired. LAN users keep `jellyfin.lab:30013`; `jf.stevengann.com` from the LAN relies on UCG NAT loopback (verify in Phase 6). |
| D-8 | **Group model** | **One group: `friends-family`.** It becomes the LDAP `search_group`. `media-users` is dropped. | Two groups with one being the LDAP scope is a "forgot to add them to the second group → Jellyfin login silently fails" trap. Narrow later if a non-media friend tier ever exists. |
| D-9 | **Exposure gate (credentials)** | Full rotation is scheduled separately, **but nothing becomes internet-reachable until the accounts that would be reachable are rotated**: the Jellyfin local admin, any Seerr/Nextcloud/Immich local admin using the shared LAN password, and the Cloudflare account gets 2FA. | A password committed to this public repo's history is in use for at least Jellyfin admin and workstation SSH. Opening `:7443` with it in place is one guess from admin. |
| D-10 | **Authentik version** | Bump `2026.5.2` → **`2026.8.1`** *before* first boot. | Authentik runs DB migrations on upgrade; first boot is the cheapest moment to be current. Pin by digest after the first pull. |
| D-11 | **MFA** | **Mandatory for admins** (`akadmin` + anyone in an admin group), **optional for friends**. | Authentik's LDAP outpost supports `password;totp` binds, but friends typing TOTP into a TV remote will not use the service. |
| D-12 | **Seerr login** | "Sign in with Jellyfin" (LDAP-backed). | Seerr `3.0.1` as deployed exposes no OIDC (verified — no `oidc` in the login bundle). Jellyfin login inherits the directory for free. Set `jellyfinExternalHost` so friend-facing links work. |
| D-13 | **Break-glass** | Every app keeps one **local admin outside LDAP/OIDC**: `akadmin`, Jellyfin admin, Homarr `credentials`, Nextcloud admin, Immich admin. | A Heimdall outage logs friends out; it must not lock *you* out. |
| D-14 | **Game servers** | **Deferred** until Thoth returns. Remove the existing open `25565` rule now. | Both servers live on Thoth, which is off. No server → no forward, and no open port to nothing. |

---

## 2. Target architecture

```
                    ┌──────────────── Internet ────────────────┐
                    │                                          │
        Cloudflare edge (public cert, WAF rate-limit on auth)  │  UCG WAN :443
                    │  tunnel (outbound from Heimdall)         │      │ port-forward
                    ▼                                          │      ▼
   ┌──────────── Heimdall 192.168.10.4 ────────────┐           │  Heimdall :7443
   │ cloudflared ──► Caddy :443 ──► Authentik :9180 │           │  (isolated Caddy
   │                        │  ──► 192.168.10.54 Seerr         │   listener, LE cert,
   │                        │  ──► 192.168.10.53 Homarr        │   serves ONLY jf)
   │                        │  ──► 192.168.10.87 Nextcloud     │      │
   │                        │  ──► 192.168.10.88 Immich (D-3)  │      ▼
   │ Authentik LDAP outpost :389/:636 ◄─────────────┼── Akasha Jellyfin :30013
   └────────────────────────────────────────────────┘   (LDAP plugin binds here)

   Identity: ONE Authentik directory.  LDAP → Jellyfin (→ Seerr).
             OIDC → Homarr, Nextcloud, Immich.  Nothing else is public.
```

**Reachable from the WAN after this plan:** Heimdall `:7443` (Jellyfin only,
host-header-isolated) and the tunnel hostnames (only through Cloudflare). **Never
WAN-reachable:** `:22`, `:80`, `:443`, `:6443`, `:389`, every `.lab` name, every
MetalLB VIP.

### 2.1 Hostname map

| Hostname | Transport | → Origin | Friend logs in with | Native client? |
|----------|-----------|----------|---------------------|----------------|
| `auth.stevengann.com` | Tunnel | Caddy `:443` → Authentik `127.0.0.1:9180` | Authentik | — |
| `seerr.stevengann.com` | Tunnel | `192.168.10.54:80` | Jellyfin (LDAP) | PWA only |
| `homarr.stevengann.com` | Tunnel | `192.168.10.53:80` | Authentik OIDC | — |
| `cloud.stevengann.com` | Tunnel | `192.168.10.87:80` | Authentik OIDC (`user_oidc`) | Desktop/mobile sync via app-password — tunnel-OK |
| `photos.stevengann.com` *(D-3)* | Tunnel | `192.168.10.88:2283` | Authentik OAuth | Immich app — tunnel-OK |
| `jf.stevengann.com` | **Direct** `:7443` | Akasha `192.168.10.247:30013` | Jellyfin (LDAP) | All Jellyfin apps |
| ~~`music.stevengann.com`~~ | — | — | — | Dropped (D-2) |
| ~~`mc` / `se`~~ | — | — | — | Deferred (D-14) |

Apex + `www` stay on GitHub Pages, grey-cloud, untouched.

### 2.2 Identity flow per pattern

- **LDAP (Jellyfin → Seerr):** friend enters username + Authentik password in the
  Jellyfin app → Jellyfin's LDAP plugin binds to `192.168.10.4:389` → outpost
  asks Authentik → user auto-created in Jellyfin on first success. Seerr's "Sign
  in with Jellyfin" replays the same credential against Jellyfin.
- **OIDC (Homarr, Nextcloud, Immich):** browser redirect to
  `https://auth.stevengann.com/application/o/<app>/` → login → redirect back.
  Immich's mobile app opens this in an in-app browser and returns to
  `app.immich:///oauth-callback`.
- **Offboarding:** deactivate the Authentik user → LDAP binds fail immediately,
  OIDC refresh fails at next token renewal. **Jellyfin device tokens do not
  expire on their own** — also delete (or disable) the user in Jellyfin to
  revoke its sessions. Add this to the onboarding runbook (§7).

---

## 3. Current state that the plan depends on (verified 2026-09-05)

| Item | State | Consequence |
|------|-------|-------------|
| `stevengann.com` nameservers | **Already on Cloudflare** | The June plan's "move DNS" prerequisite is done. |
| `jf.stevengann.com` | Exists, **orange-clouded** (proxied), times out | Must flip to grey-cloud; currently proxied to an origin that isn't there. |
| `monolith.ddns.net` / `stevengann.ddns.net` | Stale IP / NXDOMAIN; ddns-updater `unhealthy` | NoIP chain is dead. Motivates D-5. |
| `Heimdall/secrets/env.sops.env` | All six `AUTHENTIK_*` values present and real (decryptable on owner-thinkpad) | Blocker 1 of the June review is cleared on the git side. |
| `/opt/Homelab/Heimdall/.env` (live) | **Only `KOMODO_*`** — Authentik vars never shipped | `deploy.sh` must run *with* secrets before Authentik starts. |
| `AUTHENTIK_LDAP_OUTPOST_TOKEN` | **Placeholder** (29 chars) | Authentik mints the real one on first boot; paste-and-redeploy step stands. |
| Authentik on Heimdall | Never run — no `database/` dir | Clean first boot; nothing to migrate. |
| `deploy.sh` | Starts Authentik **unconditionally** (cloudflared is gated, Authentik is not) | Any unrelated deploy would start a half-configured IdP. Fix in Phase 0. |
| nftables on Heimdall | No `389/636`, no `7443`; `443` and `25565` open to *any* source | LDAP blocked, `jf` unreachable, and an open port to a game server that doesn't exist. |
| Jellyfin (Akasha) | `10.11.11`, bridge network, **no LDAP plugin installed** | Plugin install is a UI step (runbook §3). Latest plugin release `v23`. |
| Seerr | `3.0.1`, no OIDC | D-12. |
| Homarr | `v1.60.0`; OIDC env fully wired, gated on `AUTH_PROVIDERS=credentials`; `homarr-secret` has the client id/secret | Phase 5 is a one-value flip. |
| Nextcloud | `34.0.3` at `.87` | Blueprint `20-provider-nextcloud.yaml` still says "not deployed" and only has a `.lab` redirect URI — update. |
| Immich | `v3.1.0` at `.88` | No blueprint yet. Add one if D-3 is yes. |
| Caddyfile | `auth.lab, auth.stevengann.com` + `jf.stevengann.com:7443` blocks exist; global `auto_https disable_redirects`; no `email` | Ready. Add `email` for LE expiry notices. |
| Caddy image | Caddy `2.11.4` + `caddy-l4` only | No DNS-01 plugin (D-6 alternative needs a rebuild). |
| Upstream | Authentik `2026.8.1`, cloudflared `2026.8.3` | Pins for Phase 0. |
| Game servers | None running (Thoth off) | D-14. |

---

## 4. Phases

Each phase has an **exit test**. Phases 1–3 are LAN-only and fully reversible;
nothing is internet-reachable until Phase 4. Jellyfin's port opens last.

### Phase 0 — Preflight (repo changes + operator gates)

**0a. Mechanical repo changes** (safe to apply as one commit; nothing deploys
until `deploy.sh` runs):

1. `Heimdall/hostconf/nftables.conf`
   - add `ip saddr 192.168.10.0/24 tcp dport { 389, 636 } accept` (LDAP from Akasha)
   - add `tcp dport 7443 accept` (the *only* WAN-facing rule)
   - tighten `tcp dport 443` / `udp dport 443` to `ip saddr $DNS_CLIENTS`
     (RFC1918 — covers LAN clients *and* the cloudflared container on the
     `172.x` Docker bridge). WAN never hits `:443` because the UCG forwards to
     `:7443`; this is defence in depth.
   - **remove** both `25565` rules (D-14)
2. `Heimdall/scripts/deploy.sh` — gate the Authentik block on
   `grep -q '^AUTHENTIK_SECRET_KEY=' /opt/Homelab/Heimdall/.env`, mirroring the
   existing `k3s-control-plane/.env` and `cloudflared/credentials.json` gates.
3. `Heimdall/authentik/docker-compose.yml` — `2026.5.2` → `2026.8.1` (server,
   worker, ldap).
4. `Heimdall/authentik/blueprints/30-provider-ldap.yaml` — `search_group:
   friends-family`; delete `media-users` from `00-groups.yaml` (D-8).
5. `Heimdall/authentik/blueprints/20-provider-nextcloud.yaml` — add strict
   redirect `https://cloud.stevengann.com/apps/user_oidc/code`, set
   `meta_launch_url: https://cloud.stevengann.com`, drop "not deployed" text.
6. **If D-3 = yes:** new `40-provider-immich.yaml` — OAuth2 provider, redirects
   `https://photos.stevengann.com/auth/login`, `https://photos.stevengann.com/user-settings`,
   `app.immich:///oauth-callback`; application `immich`; bound to `friends-family`.
7. `Heimdall/cloudflared/config.yml` — remove `music`; uncomment `cloud` →
   `http://192.168.10.87`; add `photos` → `http://192.168.10.88:2283` (D-3).
   `docker-compose.yml` — pin `cloudflare/cloudflared:2026.8.3`, drop `pull_policy: always`.
8. `Heimdall/caddy/Caddyfile` — add `email <operator>` to the global block.
9. `Heimdall/cloudflared/README.md`, `sso-bring-up.md` §7/§8, `sso-plan.md`
   header — reflect the hostname map above.

**0b. Operator gates** (hands-on; nothing in 0a depends on them, but Phase 4+
does):

- [ ] **Cloudflare account: enable 2FA.** It now controls your DNS and your
      tunnel — it is the highest-value account in this plan.
- [ ] **Rotate the exposure set (D-9):** Jellyfin admin password; any Seerr /
      Nextcloud / Immich local admin sharing the leaked password. Record which
      accounts are considered rotated in `docs/todo.md`.
- [ ] Create a **scoped Cloudflare API token** (`Zone → DNS → Edit`, zone
      `stevengann.com` only) for ddns-updater. Re-author
      `Heimdall/secrets/ddns-config.json.sops` for the `cloudflare` provider
      (`owner: jf`, `proxied: false`, `ip_version: ipv4`). This replaces the
      three NoIP entries.
- [ ] Decide D-3 (Immich).

**Exit:** `git push`; `deploy.sh --dry-run` shows Authentik gated *off* (env not
shipped yet); nftables reload plan reviewed.

### Phase 1 — Authentik on Heimdall (LAN only)

1. Apply nftables: on Heimdall, `sudo install -m 0644 /opt/Homelab/Heimdall/hostconf/nftables.conf /etc/nftables.conf && sudo nft -f /etc/nftables.conf`
   (the file does a table-scoped reset, so this is live-safe — it was designed
   after the 2026-06-03 `flush ruleset` outage). Confirm `:6443` still
   reachable from a Pi afterwards.
2. From **owner-thinkpad** (the only host with the operator key):
   `cd Heimdall && ./scripts/deploy.sh` — *with* secrets. Ships the
   `AUTHENTIK_*` vars; the new gate lets Authentik start.
3. Browser on the LAN → `https://auth.lab` (internal CA) → log in as `akadmin`
   with `AUTHENTIK_BOOTSTRAP_PASSWORD`. **Immediately enrol TOTP on `akadmin`** (D-11).
4. Verify the worker applied the blueprints: group `friends-family`, providers
   Homarr / Nextcloud / LDAP (/ Immich), outpost `LDAP`.
5. Copy the LDAP outpost token (Applications → Outposts → LDAP → View
   deployment info) into `env.sops.env` → `AUTHENTIK_LDAP_OUTPOST_TOKEN` →
   `deploy.sh` again. The `ldap` container goes healthy.
6. Create **one test friend** in `friends-family` with a known password.

**Exit:** `ldapsearch -H ldap://192.168.10.4 -D "cn=<testfriend>,ou=users,DC=lab,DC=homelab" -w '<pw>' -b "DC=lab,DC=homelab" "(cn=<testfriend>)"` from **Akasha** returns the user. That proves outpost, token, nftables and Akasha reachability in one shot.

**Rollback:** `docker compose -p authentik down` (volumes kept). No app depends on it yet.

### Phase 2 — Jellyfin over LDAP (the bot replacement)

Runbook §3, on Akasha's Jellyfin UI:

1. Dashboard → Plugins → Catalog → **LDAP Authentication** (v23) → restart Jellyfin.
2. Configure: server `192.168.10.4`, port `389` (or `636`; the LAN hop is one
   switch — `389` is acceptable, `636` if the plugin accepts the outpost's
   self-signed cert cleanly), base DN `DC=lab,DC=homelab`, user search base
   `ou=users,DC=lab,DC=homelab`, filter `(&(objectClass=user)(cn={username}))`,
   username attribute `cn`, bind DN = a dedicated Authentik service account in
   `friends-family` (create it; never use `akadmin`).
   Enable **user creation**; LDAP users are **not** admins.
3. Jellyfin → Dashboard → General: enable login **lockout** after N failures
   (this is the only brute-force control on the direct path).
4. Verify the local admin still logs in (break-glass, D-13).

**Exit:** the test friend logs into the **Jellyfin mobile app** (not the web
UI) against `http://jellyfin.lab:30013` on the LAN, and a Jellyfin user was
auto-created for them.

**Rollback:** disable the plugin; local accounts are untouched.

### Phase 3 — Seerr + local hygiene (LAN)

1. Seerr → Settings → Users: **Jellyfin login enabled**, local login kept for
   the admin only; set `jellyfinExternalHost = https://jf.stevengann.com`
   (friend-facing links).
2. Test friend signs into `seerr.lab` with "Sign in with Jellyfin".
3. Confirm every break-glass account (D-13) exists and is rotated (D-9).

**Exit:** test friend requests a title in Seerr; it appears in Radarr/Sonarr.

### Phase 4 — Cloudflare Tunnel (first internet exposure — browser apps only)

Runbook §7 + `Heimdall/cloudflared/README.md`, on owner-thinkpad:

1. `cloudflared tunnel login` → `cloudflared tunnel create heimdall` → UUID into
   `config.yml`; `sops --encrypt … > secrets/cloudflared-credentials.sops`; commit.
2. **Route `auth` only first:** `cloudflared tunnel route dns heimdall auth.stevengann.com`.
   `deploy.sh` (the credentials gate now passes) → tunnel comes up.
3. **From a phone on cellular:** `https://auth.stevengann.com` loads with a
   Cloudflare-issued cert, login page renders, `akadmin` login works (with TOTP).
4. Cloudflare → Security → WAF → rate-limiting rule on `auth.stevengann.com`
   (e.g. 10 req/10 s per IP on `/flows/*` and `/api/v3/flows/*`).
5. Route `seerr`, `homarr`, `cloud` (and `photos`). Re-run `deploy.sh` if
   `config.yml` changed.

**Exit:** test friend, **off-network**, logs into `https://seerr.stevengann.com`
with "Sign in with Jellyfin". `https://homarr.stevengann.com` loads (still
`credentials` login — OIDC is Phase 5).

**Rollback:** `docker compose -p cloudflared down` — all public web access stops
instantly; DNS records can stay.

### Phase 5 — OIDC apps

1. **Homarr:** flip `AUTH_PROVIDERS` to `credentials,oidc` in
   `Hyperion/k8s/apps/media/20-extras/homarr/deployment.yaml`; push; Flux
   rolls it. "Sign in with Authentik" appears. Map `friends-family` to a
   Homarr group with the friend board.
2. **Nextcloud:** App store → `user_oidc` → provider: discovery
   `https://auth.stevengann.com/application/o/nextcloud/.well-known/openid-configuration`,
   client id `nextcloud`, secret from Authentik (Providers → Nextcloud). Keep
   the local admin. Verify the desktop client's browser login flow completes
   through the tunnel.
3. **Immich (D-3):** Administration → Settings → OAuth: issuer
   `https://auth.stevengann.com/application/o/immich/`, client id/secret from
   the blueprint, mobile redirect `app.immich:///oauth-callback`, auto-register
   on, storage-label from `preferred_username`. Verify in the **mobile app**
   before disabling password login for non-admins.

**Exit:** test friend logs into each via Authentik from off-network.

### Phase 6 — Jellyfin direct (the one port-forward)

Gate: **D-9 rotation done for Jellyfin admin.** Then, runbook §8 with D-5:

1. Cloudflare DNS: `jf.stevengann.com` → **delete the proxied record**; let
   ddns-updater create the grey-cloud `A` record (deploy the new
   `ddns-config.json.sops` first; confirm the container goes *healthy* and the
   record appears with the current WAN IP).
2. UCG: port-forward **WAN TCP 443 → 192.168.10.4:7443**. Nothing else.
3. Caddy already has the block; `deploy.sh --no-secrets` restarts it. Watch
   `docker logs heimdall-caddy-1` for the ACME TLS-ALPN-01 issuance.
4. **From cellular:** `https://jf.stevengann.com` shows a Let's Encrypt cert
   and the Jellyfin login. Add the server in the **Jellyfin mobile app** and
   log in as the test friend.
5. Confirm isolation: from cellular, `https://<WAN-IP>/` with any other Host
   header (e.g. `curl -k --resolve auth.stevengann.com:443:<WAN-IP> https://auth.stevengann.com/`)
   returns nothing useful from `:7443`. `.lab` names must not resolve publicly.
6. From the LAN, `https://jf.stevengann.com` — tests UCG NAT loopback (D-7).
   If it fails, LAN users use `jellyfin.lab:30013`; do **not** add `jf` to the
   `:443` Caddy listener, that would break the isolation property.

**Exit:** test friend streams a video off-network in the mobile app.

**Rollback:** remove the UCG forward. The listener, DNS and cert are inert
without it.

### Phase 7 — Hardening, monitoring, docs

- **Uptime Kuma:** HTTPS monitors for `auth`, `seerr`, `homarr`, `cloud`,
  `photos`, `jf` (these traverse the real public path); TCP monitor
  `192.168.10.4:389`; keyword monitor on the tunnel's Cloudflare status if wanted.
- **Backup the identity database.** Authentik's Postgres lives on Heimdall's
  local disk, unbacked — losing it loses every friend account. Nightly
  `pg_dump` from the `postgresql` container to an Akasha NFS path (this folds
  into the open C4/C5 backup item in `docs/todo.md`).
- **Pins:** after first pull, pin Authentik and cloudflared by digest; bump
  monthly. Authentik upgrades run migrations — back up first.
- **Docs:** `docs/homelab-user-guide.md` gets a "From outside the house" section
  with the public URLs; write the friend onboarding sheet (§7 below).
- **Repo hygiene:** the `music`/`mc`/`se` references in `sso-plan.md` §8 get a
  "deferred/dropped" note; `docs/todo.md` links this plan.

---

## 5. Security model

**Trust boundaries**

- *Internet → Cloudflare → tunnel → Caddy → app.* Cloudflare terminates TLS
  and can rate-limit. cloudflared makes only outbound connections; `config.yml`
  ends in `http_status:404`, so unlisted hostnames are refused at the edge.
  Every app on this path has Authentik (or Authentik-via-Jellyfin) as its gate.
- *Internet → UCG:443 → Heimdall:7443 → Akasha:30013.* One port. The listener
  serves exactly one hostname; a WAN client cannot reach `:443`/`:80` and
  therefore cannot reach `auth`, Komodo, Technitium, Pi-hole or any `.lab`
  admin UI. Jellyfin's gate is its own login (LDAP-backed) + lockout.
- *LAN.* Unchanged. `.lab`, MetalLB VIPs, SSH, k3s API stay RFC1918-only.

**What an attacker gets per compromise**

| Compromised | Blast radius | Mitigation |
|-------------|--------------|------------|
| A friend's Authentik password | That friend's Jellyfin libraries, Seerr requests, their Homarr/Nextcloud/Immich data | Deactivate user; optional MFA; Authentik reputation lockout; CF rate-limit on `auth` |
| Jellyfin local admin | Full Jellyfin (media, users) — **not** the directory | D-9 rotation; lockout; LDAP users never admin |
| `akadmin` | The directory: every friend account, every OIDC client | Mandatory TOTP (D-11); bootstrap password in SOPS only; `auth` only reachable via tunnel + rate-limit |
| Cloudflare account | DNS + tunnel = your entire public presence | 2FA (Phase 0b); scoped API tokens only |
| Heimdall host | Everything above plus DNS and the k3s control plane | Out of scope here; already the lab's known concentration risk (`todo.md`) |

**Deliberately not done:** Cloudflare Access (D-4); fail2ban on the direct
Jellyfin path (Caddy has no plugin for it in the current image; Jellyfin's own
lockout is the control — revisit with DNS-01/image rebuild if abuse appears);
self-service enrollment (needs SMTP; friends are provisioned by you).

**Availability:** Heimdall outage = friends lose everything (auth, tunnel, DNS).
Accepted, monitored. Break-glass admins (D-13) keep *you* in. Moving the k3s
control plane off Heimdall (existing item) shrinks Heimdall's blast radius in
the other direction but does not change this one.

---

## 6. Repo changes summary

| File | Phase | Change |
|------|-------|--------|
| `Heimdall/hostconf/nftables.conf` | 0a | +389/636 LAN, +7443 WAN, 443→RFC1918, −25565 |
| `Heimdall/scripts/deploy.sh` | 0a | Gate Authentik on shipped `AUTHENTIK_SECRET_KEY` |
| `Heimdall/authentik/docker-compose.yml` | 0a | Pin `2026.8.1` |
| `Heimdall/authentik/blueprints/00-groups.yaml`, `30-provider-ldap.yaml` | 0a | Single `friends-family` group as LDAP scope |
| `Heimdall/authentik/blueprints/20-provider-nextcloud.yaml` | 0a | Public redirect URI + launch URL |
| `Heimdall/authentik/blueprints/40-provider-immich.yaml` *(new, D-3)* | 0a | Immich OAuth provider |
| `Heimdall/cloudflared/config.yml`, `docker-compose.yml` | 0a | Hostname map; pin `2026.8.3` |
| `Heimdall/caddy/Caddyfile` | 0a | `email` in global block |
| `Heimdall/secrets/ddns-config.json.sops` | 0b | Cloudflare provider (operator, needs token) |
| `Heimdall/secrets/env.sops.env` | 1 | Real `AUTHENTIK_LDAP_OUTPOST_TOKEN` |
| `Heimdall/secrets/cloudflared-credentials.sops` *(new)* | 4 | Tunnel credentials |
| `Hyperion/k8s/apps/media/20-extras/homarr/deployment.yaml` | 5 | `AUTH_PROVIDERS=credentials,oidc` |
| `docs/homelab-user-guide.md`, `docs/todo.md`, `sso-plan.md`, runbook | 7 | Public URLs; pointers; drop `music`/games |

Not in the repo (UI/operator): Jellyfin LDAP plugin + lockout; Seerr Jellyfin
login + external host; Nextcloud `user_oidc`; Immich OAuth; UCG port-forward;
Cloudflare 2FA, tunnel creation, DNS routing, WAF rule, API token; Uptime Kuma
monitors; TOTP on `akadmin`.

---

## 7. Onboarding a friend (the runbook this replaces the bot with)

1. Authentik → Directory → Users → **Create**: username (this is what they type
   into the Jellyfin app), name, email; set a temporary password; add to
   `friends-family`.
2. Send them three things: `https://homarr.stevengann.com` (start here),
   `https://jf.stevengann.com` (paste as the server in the Jellyfin app), and
   their username + temporary password. Ask them to change it at
   `https://auth.stevengann.com` (User settings → Password).
3. First Jellyfin login auto-creates their Jellyfin user with default library
   access; adjust libraries in Jellyfin → Users if needed.
4. **Offboarding:** Authentik → deactivate; **Jellyfin → delete the user** (this
   is what actually revokes their app sessions); Seerr → remove the user.

---

## 8. Deferred (explicitly out of scope for this plan)

- **Game servers** (`mc`, `se`) — when Thoth returns. Raw TCP/UDP cannot use the
  free tunnel; that will be 1–2 more forwards, or Spectrum/a relay if you want
  zero home-IP exposure. Re-add the nftables rules then.
- **Navidrome** for friends — D-2. Only if a client ecosystem with IdP-capable
  auth (OpenSubsonic API keys) becomes usable.
- **Self-service enrollment / invites** — needs SMTP.
- **Cloudflare Access** — D-4.
- **DNS-01 for Caddy** — D-6; rebuild the image with `caddy-dns/cloudflare` if
  the TLS-ALPN ordering constraint ever bites.
- **Full credential rotation + history scrub** — scheduled separately; D-9 is
  the minimum gate for exposure.
