# Senior Dev — Clean Code & Tech-Debt Steward

> Notes doc for the Temperature Sensor project. See [TEAM.md](./TEAM.md) for roles
> and protocol. This member is the sole writer of record for this file.

## Settled Knowledge

_(durable, verified facts accumulate here)_

### ESPHome config-composition primitives (verified 2026-06-14)

- **`substitutions:`** — top-level block of shell-style variables. Reference with
  `$var` or `${var}` (equivalent, case-sensitive). Values may be any YAML type
  (scalar, list, dict). Dotted/indexed access works inside `${...}`
  (`${device.name}`, `${unused_pins[2]}`) and simple Jinja expressions are
  supported (`${native_width * 2 if high_dpi else native_width}`). `!literal`
  suppresses substitution.
  Source: <https://esphome.io/components/substitutions/>
- **CLI override:** `esphome -s <key> <value> config example.yaml` overrides a
  substitution and takes precedence over the file value — enables one template +
  per-node values from a script.
  Source: <https://esphome.io/components/substitutions/>
- **`!secret <key>`** reads from `secrets.yaml` **in the same directory as the
  config file being processed**. For a package pulled from a subdirectory, `!secret`
  resolves against a `secrets.yaml` in *that* subdirectory, not the root. Workaround
  for a single shared secrets file: put `<<: !include ../secrets.yaml` in a child
  `secrets.yaml`. The secrets file must be a flat mapping of keys to scalar values.
  Sources: <https://esphome.io/guides/faq/>,
  <https://github.com/esphome/issues/issues/1656>,
  <https://community.home-assistant.io/t/error-reading-secrets-yaml-in-parent-directory/128575>
- **`packages:`** — merges config trees intelligently (lists concatenate, dicts
  deep-merge), unlike `!include` which is a raw splice. Use packages when multiple
  files contribute to the same section (e.g. several `sensor:` blocks). Forms:
  - Local list: `packages: [ !include common/wifi.yaml, ... ]`
  - Local mapping: `packages: { wifi: !include common/wifi.yaml }`
  - Parameterized local include (per-node vars):
    ```yaml
    packages:
      node: !include
        file: common/temp-node.yaml
        vars:
          node_name: bedroom
    ```
  - Remote/git shorthand: `github://user/repo/file.yml@ref`
  - Remote/git full form: `url:`, `files: [...]`, `ref:`, `refresh: 1d`,
    `username:`/`password:`.
  Source: <https://esphome.io/components/packages/>
- **Remote packages CANNOT use `!secret`.** They must declare `substitutions:`
  with default values; the consuming device YAML overrides them with values pulled
  from the *local* `secrets.yaml`. (Local includes in this same repo CAN use
  `!secret` since the secrets file ships alongside.)
  Source: <https://esphome.io/components/packages/>
- **Device Builder (ESPHome 2026.5.0+)** can queue/compile multiple devices at
  once — relevant for a multi-node fleet.
  Source: <https://www.xda-developers.com/esphome-device-builder-lets-compile-multiple-devices-at-once/>

## Working Notes

_(in-flight thinking, dated entries)_

### 2026-06-14 — Layout, tech-debt, secrets recommendation

**Repo placement.** Per `Homelab/CLAUDE.md`, top-level dirs map to physical
hosts/clusters. `Sensors/` is a deviation already in place; treat `Sensors/` as a
device-class grouping and `Sensors/Temperature/` as this project root. All ESPHome
config lives under it. No change to the host-mapping convention needed for tiny
distributed sensor nodes (they are not "a host" in the cluster sense).

**Proposed file/dir layout** (DRY-first, scales to N identical nodes):

```
Sensors/Temperature/
├── README.md                     # how to flash/add a node, wiring 1-liner
├── .gitignore                    # ignores secrets.yaml + .esphome/ build cache
├── secrets.yaml.example          # committed template, real one gitignored
├── secrets.yaml                  # GITIGNORED — real WiFi/MQTT/API/OTA creds
├── common/
│   └── dht22-node.yaml           # the ONE shared package: wifi+api+mqtt+ota+
│                                 #   logger+dht22 sensor, all parameterized by
│                                 #   ${node_name}, ${dht_pin}, ${update_interval}
└── nodes/
    ├── temp-bedroom.yaml         # ~10 lines: substitutions + packages: !include
    ├── temp-garage.yaml
    └── temp-livingroom.yaml      # adding a node = copy one small file
└── docs/                         # (existing) plan + team notes
```

Per-node file is intentionally thin:

```yaml
# nodes/temp-bedroom.yaml
substitutions:
  node_name: temp-bedroom
  friendly_name: "Bedroom Temperature"
  dht_pin: D4                       # GPIO2 on D1 mini — defer pin to Embedded SME
  update_interval: 60s
packages:
  base: !include
    file: ../common/dht22-node.yaml
    vars:
      node_name: ${node_name}
      friendly_name: ${friendly_name}
      dht_pin: ${dht_pin}
      update_interval: ${update_interval}
```

Shared package uses `!secret` for credentials (legit because secrets.yaml ships in
this repo dir, not a remote package):

```yaml
# common/dht22-node.yaml  (sketch — HA/MQTT + Embedded SMEs own the details)
esphome:
  name: ${node_name}
esp8266:
  board: d1_mini
wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
api:
  encryption:
    key: !secret api_encryption_key
ota:
  - platform: esphome
    password: !secret ota_password
mqtt:
  broker: !secret mqtt_broker
  username: !secret mqtt_username
  password: !secret mqtt_password
logger:
sensor:
  - platform: dht
    model: DHT22
    pin: ${dht_pin}
    temperature:
      name: "${friendly_name} Temperature"
    humidity:
      name: "${friendly_name} Humidity"
    update_interval: ${update_interval}
```

**Top tech-debt traps & mitigations:**
1. **Plaintext secrets committed.** Mitigation: `secrets.yaml` gitignored +
   `secrets.yaml.example` template committed. (Strategy details below.)
2. **Copy-paste-divergence across nodes** — the classic ESPHome anti-pattern of
   full per-device YAML files that drift. Mitigation: single `common/` package,
   per-node files carry only substitutions. One bug fix propagates to all nodes.
3. **Hardcoded pins/intervals/board** scattered in device files. Mitigation: all
   tunables are substitutions with sane defaults in the package.
4. **`!include` where `packages` is needed.** If a node ever needs to *add* a
   sensor, raw `!include` clobbers; `packages` merges. Default to `packages:`.
5. **Build cache (`.esphome/`) committed.** Gitignore it; it is regenerated.
6. **Gold-plating.** For a DHT22 reporting temp+humidity, resist deep-sleep,
   web_server, captive portal, extra filters, multiple update intervals, etc.
   unless an explicit requirement appears. Native API + MQTT + OTA + logger is the
   minimal viable set. Flag scope creep to the team.
7. **Native API AND MQTT both on** can double-report to HA (MQTT discovery +
   native API). HA/MQTT SME should confirm whether MQTT discovery should be
   disabled to avoid duplicate entities — note as an open question, not my call.

**Secrets strategy recommendation (gitignore, NOT SOPS):**
- The repo uses SOPS+age for Hyperion/Heimdall because those secrets are
  *deployed by CI/scripts that need to decrypt non-interactively*. ESPHome is
  different: the human compiles/flashes from a workstation that already holds
  `secrets.yaml` locally, and ESPHome's `!secret` reads plaintext at compile time.
  There is no CI decryption step in the flash loop.
- Therefore: **gitignore `secrets.yaml`, commit `secrets.yaml.example`.** This is
  the idiomatic ESPHome pattern and the lowest-friction repeatable workflow. It
  keeps zero plaintext creds in git (satisfies the security rule) without bolting
  a SOPS/age decrypt step into every `esphome run`.
- *If* the team later wants the encrypted secrets to live in-repo (audit/restore),
  the clean compromise is a committed `secrets.sops.yaml` (SOPS+age, matching the
  repo convention) + a one-line decrypt-to-`secrets.yaml` step in the README/flash
  script. I recommend deferring that until there's a real need — it's gold-plating
  for a handful of sensor nodes today. Raise to Devil's Advocate for challenge.
- Add the project `secrets.yaml` (and `.esphome/`) to the project `.gitignore`.
  The root `Homelab/.gitignore` already ignores `.env` and `*.local.yaml`, but NOT
  `secrets.yaml` — so a dedicated `Sensors/Temperature/.gitignore` is required.

**Open questions handed to other members:**
- Embedded SME: confirm DHT22 GPIO on D1 mini and whether to set
  `pin: { number: ..., mode: INPUT_PULLUP }`; confirm `dht` platform spec.
- HA/MQTT SME: native API encryption key generation, MQTT topic/retain/QoS,
  duplicate-entity concern when both API and MQTT are enabled.
- Fact Checker: all Settled Knowledge URLs above are cite-ready.

### 2026-06-14 — Round 1 vote

**VOTE: NAY**

**Blocking defect — `!secret` cannot resolve from the layout as drawn.**
The shared package `common/dht22-node.yaml` uses `!secret` for every credential
(wifi/api/ota/mqtt/fallback-ap), but the only `secrets.yaml` in §4 lives at the
project ROOT (`Sensors/Temperature/secrets.yaml`). Per my own Settled Knowledge
(lines 23-30) and re-verified against current ESPHome docs today, `!secret`
resolves relative to the directory of the file that **contains the tag** — here
`common/` — NOT the entrypoint dir (`nodes/`) and NOT the CWD where `esphome` is
invoked. So ESPHome looks for `common/secrets.yaml`, doesn't find it, and
`esphome config`/`run` fails to read every secret on first contact. The §10
checklist item "`esphome config` validates" would fail immediately.

**Fix (minimal, idiomatic — the documented merge-key relay):** add a thin relay
`common/secrets.yaml` containing exactly:
```yaml
<<: !include ../secrets.yaml
```
Keep the single real `secrets.yaml` (and its `.example`) at the project root.
The per-node files in `nodes/` use only `substitutions:` (no `!secret`), so no
`nodes/secrets.yaml` relay is needed. Add the relay file to `.gitignore`-awareness
docs (it carries no secrets itself, so it can be committed, but call it out in §4
and §6 so it isn't mistaken for a real secrets file). With this one file added,
the rest of the plan is sound.

**Reasoning:**
- This is a hard compile-time failure, not a style nit — the plan as written
  does not flash. It must be fixed before any YAML lands.
- The DRY layout (single `common/` package, thin per-node substitution files) is
  exactly what I recommended; the `packages:` deep-merge choice is correct and
  future-proofs adding sensors. Good.
- Secrets-hygiene interim is sound: gitignored placeholder `secrets.yaml` +
  committed `.example`, SOPS deferred cleanly with a drop-in decrypt step. The
  pre-commit grep guard (DA #4) is a sensible belt-and-suspenders, not gold-plating.
- D5/GPIO14 standardization and striking the old D4 example resolves the
  strapping-pin/LED hazard I flagged — and supersedes the stale `dht_pin: D4` in
  my own earlier sketch (lines 95, 102). Good catch by the team.
- Gold-plating is well controlled: deep-sleep / web_server / extra sensors all
  deferred to §11. `captive_portal` + fallback `ap:` is justified as the
  headless OTA-recovery net, not creep — acceptable.
- `reboot_timeout: 0s` (API + MQTT both on) and `filter_out: nan` are correct,
  minimal mitigations, not over-engineering.

**NIT (non-blocking):** §4 ASCII tree shows the package using `!include` while
my notes prefer the parameterized `packages: !include {file:, vars:}` form so a
node can override substitutions explicitly; the plan instead relies on
substitution inheritance via deep-merge, which also works. Either is fine — no
change required.

**NIT (non-blocking):** §6 lists `fallback_ap_password` among required keys
(good — it's referenced by `wifi: ap:`), but the §10 generation note only calls
out `api_encryption_key` and "OTA/AP passwords." Just ensure the `.example`
enumerates all 8 keys, which §6 already does.

### 2026-06-14 — Round 1 re-vote

**VOTE: YAE**

The blocking `!secret` resolution defect from my Round-1 NAY is fully resolved.
Re-read §4, §5.1, §6:
- §4 now lists `common/secrets.yaml` in the tree.
- §5.1 carries the exact fix: `!secret` resolves relative to the file containing
  the tag (`common/`); `common/secrets.yaml` is a one-line relay
  `<<: !include ../secrets.yaml` to the single root `secrets.yaml`; per-node
  files use only `substitutions:` so `nodes/` needs no relay. This matches my
  Settled Knowledge (lines 23-30) and the re-verified ESPHome docs exactly.
- §6 correctly states the relay holds no values and is therefore committed,
  distinguishing it from the gitignored real `secrets.yaml`.

`esphome config`/`run` will now find every secret. No other blocker. The DRY
layout, deep-merge packages choice, D5/GPIO14 standardization, interim
gitignore-placeholder secrets with SOPS deferred, and gold-plating discipline
all stand from Round 1.

**NIT (non-blocking, for the README/.gitignore author):** §6 ignores
`secrets.yaml` by bare name. A gitignore pattern with no leading slash matches at
any depth, so `secrets.yaml` will also match the committed relay
`common/secrets.yaml`. Use an anchored pattern (`/secrets.yaml`) or an explicit
un-ignore (`!common/secrets.yaml`) so the relay commits without needing
`git add -f`. Trivial implementation detail; the plan's intent is unambiguous and
this does not affect the vote.
