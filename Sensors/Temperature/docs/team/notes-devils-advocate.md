# Devil's Advocate — Adversarial Reviewer

> Notes doc for the Temperature Sensor project. See [TEAM.md](./TEAM.md) for roles
> and protocol. This member is the sole writer of record for this file.

## Settled Knowledge

_(durable, verified facts accumulate here)_

### Decisions the plan MUST resolve before it can be voted YAE (carried from 2026-06-14 review)

These are the binding ASKs distilled from the Working Notes below. The plan author
must answer each one explicitly (a sentence + the chosen config), not implicitly.

1. **DUAL-PUBLISH JUSTIFICATION.** State the *named MQTT consumer* that justifies
   running `mqtt:` in addition to `api:`. If none exists today, default to API-only
   and drop `mqtt:` from the package (keep it as a documented, parameterized opt-in).
2. **`api: reboot_timeout: 0s` IS MANDATORY** the moment `mqtt:` ships, regardless of
   how reliably HA is connected. There is no scenario in this project where the
   default 15-min API-reboot is desirable. Bake it into the shared package, not the
   per-node file.
3. **`mqtt: discovery: false`** whenever `api:` is the HA path (avoids duplicate
   entities). Non-negotiable if both components ship.
4. **DHT22 is accepted as a hard requirement, but the plan MUST carry a one-line
   "known-inferior sensor" note** pointing at SHT3x / BME280 / AHT20 (I2C, faster,
   tighter tolerance) so the choice is informed, not accidental.
5. **`filter_out: nan` on both sub-sensors is REQUIRED, not "recommended".** A DHT22
   with no NaN filter pushes NaN into HA long-term statistics and into retained MQTT
   state — a retained NaN is a persistent lie to every new subscriber.
6. **`secrets.yaml` MUST be gitignored by a committed `Sensors/Temperature/.gitignore`
   that lands BEFORE any file that can reference it.** Root `Homelab/.gitignore` does
   NOT cover `secrets.yaml` (verified 2026-06-14: it lists only `.env` and two
   Heimdall paths). Gitignore-only is accepted for now ONLY with the WN-4 guardrails
   (pre-commit/CI grep + example file).
7. **Pick ONE ESPHome install method and name it in the README** (HA add-on vs `pip`
   vs Docker vs web flasher). Embedded SME assumes `pip` + `/dev/ttyUSB0`; HA/MQTT SME
   assumes the HA add-on. Those are different serial-access and OTA stories.
8. **DHT data pin = D5/GPIO14 is endorsed.** Do NOT use D3/D4/D8 (strapping) or
   D0/GPIO16 (no one-wire). `pullup:` MUST match the physical hardware (bare sensor →
   external 4.7k + default/`true`; breakout module → `pullup: false`). The plan must
   state WHICH hardware the user actually has.

## Working Notes

_(in-flight thinking, dated entries)_

### 2026-06-14 — Adversarial review pass over all three SME notes

Context grounding (verified, not assumed):
- No firmware/config exists yet — only `docs/`. (`find` over the project, 2026-06-14.)
- No `Sensors/Temperature/.gitignore` exists. Root `Homelab/.gitignore` ignores
  `.env` and two `Heimdall/secrets/*` paths only — **`secrets.yaml` is NOT ignored
  anywhere yet.** Right now a naive `git add .` would commit plaintext WiFi creds.

---

#### CHALLENGE 1 — "Publish to BOTH API and MQTT" is unjustified complexity by default

- **Claim challenged** (HA/MQTT SME §1; Senior Dev trap #7; TEAM mission): the device
  should publish to HA via native API **and** to an MQTT broker simultaneously.
- **Risk:** Both-on is the single largest source of footguns in this plan:
  - The **15-min API reboot loop** (HA/MQTT SME's own "REBOOT TRAP"). A headless node
    that silently reboots every 15 minutes when HA's API client drops looks exactly
    like flaky hardware and will burn hours of misdiagnosis.
  - **Duplicate entities** in HA (API copy + MQTT-discovery copy) → "entity id already
    exists", manual cleanup, confusion about which entity's history is real.
  - **Double source of truth:** retained MQTT state vs API state can disagree (after a
    NaN, after a reboot). Which one is "the temperature"?
  - **Setup-blocking caveat** (esphome/issues#3695): an unreachable broker can stall
    `setup()` and take the *API* path down with it. Adding MQTT can make the *primary*
    (API) path **less** reliable than API-alone — the opposite of belt-and-suspenders.
  - Extra RAM pressure on a 4MB ESP8266 running API + MQTT (+ TLS) — HA/MQTT SME
    flagged this as a real open item.
- **Hidden assumption:** that a non-HA MQTT consumer exists. Nobody has named one. If
  HA is the only consumer, MQTT is pure redundant surface area — the API already
  delivers everything to HA, more efficiently.
- **Counter to the "it's the requirement" reflex:** the mission says publish to HA
  *and* MQTT, but a requirement to *be able to* feed a broker is not the same as
  *both must always be live on every node*. The cheap, reversible default is API-only
  with `mqtt:` as a one-substitution per-node opt-in.
- **ASK:** Name the concrete MQTT consumer (Node-RED? Grafana/Telegraf? another host?).
  If you cannot name one that needs MQTT specifically, the plan ships **API-only** and
  keeps `mqtt:` as a documented, defaulted-off package option. If you keep both, the
  plan MUST set `api: reboot_timeout: 0s` AND `mqtt: discovery: false` AND document
  which entity is canonical.

---

#### CHALLENGE 2 — DHT22 is a mediocre sensor; the plan must acknowledge it (not hide it)

- **Claim challenged** (all three notes treat DHT22 as a given): DHT22/AM2302 is the
  right sensor.
- **Risk:** DHT22 is genuinely poor by 2026 standards and the notes already document
  its failure modes without connecting the dots: ±0.5°C accuracy, slow (≥2s, 60s
  practical), one-wire timing sensitive to cable/pull-up, frequent **NaN dropouts**,
  no I2C, humidity drift over time. The Embedded SME's "NaN causes" list and the
  mandatory filtering are symptoms of a weak sensor choice. A future reader will
  assume DHT22 was chosen on merit when it was likely "it's in the drawer."
- **Better drop-in alternatives (same 3.3V, similar wiring, ESPHome-native):**
  - **SHT3x / SHT4x (I2C):** ±0.2°C, fast, rock-solid; uses D1/D2 — the I2C pins the
    Embedded SME *deliberately left free*. Strongly preferred if buying new.
  - **BME280 (I2C):** temp + humidity + pressure, cheap, ubiquitous.
  - **AHT20 (I2C):** very cheap, far more reliable than DHT22.
- **I am NOT asking to change the requirement** — only to carry the tradeoff in writing.
- **ASK:** Add a one-line "sensor selection" note to the plan: DHT22 used per existing
  hardware; SHT3x/BME280/AHT20 (I2C) are superior drop-ins for future nodes. AND make
  `filter_out: nan` mandatory (Challenge 6).

---

#### CHALLENGE 3 — GPIO/pull-up correctness depends on hardware nobody has confirmed

- **Claim challenged** (Embedded SME §2–3; Senior Dev's `dht_pin: D4` example).
- **Risk A — the Senior Dev's example uses `dht_pin: D4`.** D4 = GPIO2 = a **strapping
  pin** AND the **onboard active-LOW LED**. The Embedded SME correctly recommends
  **D5/GPIO14**. The two notes' concrete examples disagree. If `D4` survives into the
  template, the device may fail to boot if the sensor pulls the line low at boot, and
  LED/sensor will conflict. Live inconsistency.
- **Risk B — `pullup` mismatch → intermittent NaN.** The most common DHT22 field
  failure. Bare 3-pin AM2302 needs an external 4.7k–10k pull-up (`pullup` default/true);
  a breakout module already has one and needs `pullup: false`. Backwards = no pull-up
  (NaN) or double pull-up (works but wrong). The plan doesn't state which hardware exists.
- **Risk C — strapping pitfalls generally:** D3/GPIO0 (fails if LOW), D8/GPIO15 (fails
  if HIGH), D0/GPIO16 (no one-wire/interrupt) are traps a copy-paste author could hit.
- **ASK:** (1) Fix template/examples to use **D5/GPIO14** everywhere; strike the `D4`
  example. (2) Record whether the user's DHT22 is a **bare 3-pin sensor** or a
  **breakout module** and set `pullup` + external-resistor instructions accordingly.
  Document both cases.

---

#### CHALLENGE 4 — Gitignore-only secrets in a shared monorepo is one `git add -f` from a leak

- **Claim challenged** (Senior Dev "Secrets strategy: gitignore, NOT SOPS").
- **Risk:**
  - **It isn't ignored yet.** Verified: no project `.gitignore`, root ignores don't
    cover `secrets.yaml`. Until that file lands the protection is zero — order of
    operations matters: the ignore must exist before anyone runs `git add`.
  - `git add -f secrets.yaml` (or an editor "commit all", or a future `git add .`
    after a rename) bypasses gitignore silently. In a multi-contributor monorepo that
    leaks live WiFi PSK + MQTT creds + API encryption key + OTA password into history
    forever (history rewrite to purge; creds must be rotated).
  - The rest of this repo uses **SOPS+age** precisely because plaintext secrets in git
    are unacceptable here. "ESPHome is different" is a real *convenience* argument
    (compile-time `!secret`, no CI decrypt) but not a *security* one — the blast radius
    of a leak is identical.
- **Steelman:** SOPS-in-the-flash-loop is genuine friction (decrypt before every
  `esphome run`) and these are low-value LAN creds. Fair — but the answer to "SOPS is
  heavy" is cheap guardrails, not "nothing beyond .gitignore."
- **ASK — pick one, plan states it:**
  - **(Minimum, required either way):** commit `Sensors/Temperature/.gitignore`
    ignoring `secrets.yaml` + `.esphome/` **first**; add a **pre-commit hook or CI
    grep** that hard-fails if `secrets.yaml` (or a PSK-looking string) is staged;
    commit `secrets.yaml.example` with dummy values.
  - **(If in-repo audit/restore wanted):** adopt repo-native `secrets.sops.yaml` + a
    one-line `sops -d` step in the flash script/README. Matches the monorepo
    convention and removes the footgun. I lean this way given the repo already
    standardizes on SOPS+age — "we use SOPS everywhere except the one place a human
    might fat-finger" is a weak exception. At minimum, force a conscious decision.

---

#### CHALLENGE 5 — Two SMEs assume two different toolchains; first-flash failure modes unowned

- **Claim challenged:** Embedded SME assumes **`pip install esphome` + `/dev/ttyUSB0`
  + dialout**; HA/MQTT SME §5 assumes **ESPHome runs as the HA add-on**. Both can't be
  the README's "the way."
- **Risk:**
  - HA add-on/dashboard runs **inside HA** — no access to the workstation's
    `/dev/ttyUSB0` unless you use the browser web-flasher (Chrome WebSerial) or "plug
    into this computer." The `dialout` + `/dev/ttyUSB0` advice is for the
    standalone/pip/Docker workstation path. A user mashing both up hits a wall on
    first flash.
  - **CH340 / brltty footgun:** device enumerates then vanishes because `brltty` grabs
    it (Embedded SME flagged) — but only on the workstation path. On the web-flasher
    path the failure is "browser isn't Chromium / no WebSerial." Different path,
    different first-failure.
  - **Docker path** needs `--device=/dev/ttyUSB0` into the container — covered by
    neither note.
- **ASK:** README declares ONE primary first-flash method with its specific prereqs and
  its specific failure + fix. Recommendation (Pop!_OS Homelab workstation): **`pip`/
  `pipx` (or Docker) ESPHome on the workstation, `/dev/ttyUSB0`, `dialout` group,
  remove `brltty` if the port disappears**; mention web.esphome.io as zero-install
  fallback. State whether OTA-from-then-on is driven from the workstation or the HA
  add-on (different hosts hold the OTA password).

---

#### CHALLENGE 6 — Reliability/headless: NaN, OTA bricking, update_interval, power

- **Claims challenged:** `update_interval: 60s`, "recommended" NaN filter, OTA for all
  subsequent flashes, USB power (across all three notes).
- **Risks:**
  - **NaN to retained MQTT + HA stats.** With `retain: true` (MQTT default) +
    `state_class: measurement` (DHT default), one NaN gets **retained** on the broker
    (every new subscriber reads NaN until the next good sample) and pollutes HA
    long-term statistics. The Embedded SME calls `filter_out: nan` "recommended"; for
    a headless sensor it's not optional. → Settled #5.
  - **OTA bricking on a headless node.** OTA is the only post-first-flash update path,
    and ESP8266 ESPHome has **no boot-time rollback menu**. A bad OTA (wrong board,
    broken WiFi, OOM from adding `web_server`) leaves a node that won't rejoin WiFi →
    **no OTA recovery → physical USB re-flash trip.** Mandate: keep `ap:`+
    `captive_portal:` fallback so a failed-WiFi node still serves a config AP; change
    ONE thing per OTA; flash a known-good node first; never enable `web_server` on this
    ESP8266 (HA/MQTT SME's own RAM warning). (Tradeoff: `ap:`+`captive_portal:` cost
    flash/RAM and broadcast a hotspot — the right call for headless recovery.)
  - **`update_interval`:** 60s is safe (DHT22 min ~2s); don't go faster (timing NaN).
    Defensible as-is; just don't let anyone "tune" it to 5s.
  - **Power/brownout:** Wi-Fi TX peaks (300–500mA) on a cheap cable/supply cause resets
    that *look like* sensor/firmware bugs. Spec a ≥500mA supply + decent cable; mention
    the 100µF bulk cap if resets persist (Embedded SME has this).
- **ASK:** Plan must (1) make `filter_out: nan` mandatory on both sub-sensors;
  (2) keep `ap:`+`captive_portal:` as the headless OTA-failure safety net; (3) state
  an OTA discipline (one change at a time, test one node, never `web_server` on
  ESP8266); (4) carry the ≥500mA-supply/good-cable note as a deploy requirement.

---

#### CHALLENGE 7 (added) — Birth/LWT + retain interact badly with the dual-publish story

- **Claim challenged** (HA/MQTT SME §3): MQTT `retain: true` + birth/will defaults are
  fine as-is.
- **Risk:** With `retain: true` the **last** temperature stays on the broker after the
  device dies. A pure-MQTT consumer (the very one that would justify Challenge 1's
  "both") reads a **stale-but-plausible** value indefinitely unless it honors the LWT
  `status=offline` topic. Silent-staleness trap: the number looks live but the sensor
  is gone.
- **ASK:** If MQTT ships, the plan must (a) keep birth/will (`status` online/offline)
  AND document that any MQTT consumer must gate on `…/status == online`, OR (b) set
  state `retain: false` and accept gaps. Direct consequence of keeping MQTT;
  reinforces Challenge 1's "name the consumer."

---

#### Net recommendation to the orchestrator

Strongest single lever: **resolve Challenge 1 first.** If the plan drops to API-only
(my default recommendation absent a named MQTT consumer), Challenges 1, 7, half of 5,
and the RAM concern largely evaporate, and the firmware gets simpler and *more*
reliable. Everything else (pin = D5, mandatory NaN filter, real gitignore + grep, one
toolchain, captive-portal recovery, DHT22 acknowledgment) is cheap and should be
adopted regardless.

### 2026-06-14 — Round 1 vote

**VOTE: YAE.** The distilled plan resolves all seven of my Round-1 challenges with
concrete config, not hand-waving, and correctly *implements* the binding operator
decisions D1–D4 rather than re-opening them.

- **C1 dual-publish — RESOLVED.** D4 binds "real non-HA MQTT consumers exist," which
  is the named justification I asked for. All three mitigations land in the *shared*
  package: `api: reboot_timeout: 0s` (§5.1, with reboot-loop rationale), `mqtt:
  discovery: false` (§5.1/§9.2), and a canonical-entity rule (§9.2). My API-only
  default was conditional on "no named consumer"; D4 removes that condition.
- **C2 DHT22 quality note — RESOLVED.** §2 carries the ±0.5°C / NaN / no-I²C note and
  points at SHT3x/BME280/AHT20 as I²C drop-ins, explicitly "a note, not a change."
- **C3 + C8 pin/pull-up — RESOLVED.** DATA standardized to D5/GPIO14 everywhere; the
  D4 example is explicitly struck (§5.2). D1 binds breakout-module hardware →
  `pullup: false`, no external resistor; §3 documents the bare-4-pin future case.
- **C4 secrets safety — RESOLVED.** Committed `.gitignore` (covers `secrets.yaml` +
  `.esphome/`) + `secrets.yaml.example` + WN-4 pre-commit grep guard (§6), with SOPS
  as drop-in end-state per D3. Validation §10 checks no plaintext leak. All my
  minimum guardrails present; the interim deviation from SOPS is operator-bound (no
  age key on the workstation today) and reversible.
- **C5 single toolchain — RESOLVED.** §7 names exactly one (ESPHome CLI via pipx, D2);
  Docker marked "not chosen, for reference"; OTA driven from the same workstation (§8).
- **C6 reliability — RESOLVED.** `filter_out: nan` mandatory on both sub-sensors;
  `ap:`+`captive_portal:` recovery net; one-change-per-OTA + never-`web_server`
  discipline; ≥500 mA supply note. All four asks met.
- **C7 retain/LWT staleness — RESOLVED.** Retained `status` online/offline + a
  consumer-must-gate-on-`status==online` rule (§9.2); power-cycle LWT flip in the
  validation checklist (§10).
- **NIT (non-blocking):** the dual-publish footgun risk would drop further if state
  topics used `retain: false` (path 7b) in addition to the LWT gate, but path 7a
  (retain + mandatory status-gate) is a legitimate, documented choice given real MQTT
  consumers may want last-value-on-connect. No change required.
