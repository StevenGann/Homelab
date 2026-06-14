# Implementation Plan — D1 mini (ESP8266) + DHT22 → Home Assistant + MQTT

**Status:** ✅ APPROVED — Round-1 re-vote **5 YAE / 0 NAY** (2026-06-14; see
[`../team/TEAM.md`](../team/TEAM.md) vote log). Project files scaffolded per this plan.
· **Date:** 2026-06-14 · **Owner:** Temperature team
(see [`../team/TEAM.md`](../team/TEAM.md))

This plan distills the Round-1 input from all five team members
([Senior Dev](../team/notes-senior-dev.md), [Embedded SME](../team/notes-embedded-sme.md),
[HA/MQTT SME](../team/notes-ha-mqtt-sme.md), [Fact Checker](../team/notes-fact-checker.md),
[Devil's Advocate](../team/notes-devils-advocate.md)) plus the operator's four binding
decisions of 2026-06-14.

## 0. Operator decisions (binding)

| # | Decision | Consequence |
|---|----------|-------------|
| D1 | DHT22 is a **3-pin breakout module** (onboard pull-up) | `pullup: false`; **no external resistor** |
| D2 | Toolchain = **ESPHome CLI via pipx** | First flash over USB with `esphome run`; OTA thereafter |
| D3 | Secrets = **SOPS+age** (match monorepo) — **target end-state** | **Interim (2026-06-14):** this workstation has no age key, so ship a **gitignored `secrets.yaml` with placeholders** + committed `secrets.yaml.example`; wire up SOPS encryption later (§6) |
| D4 | **Real non-HA MQTT consumers exist** | MQTT is a full second output; `mqtt: discovery: false` (HA uses native API); consumers must status-gate |

## 1. Goal & scope

Firmware (ESPHome) for a **WeMos/LOLIN D1 mini (ESP8266EX)** that reads a **DHT22
(AM2302)** and publishes temperature + humidity to:
- **Home Assistant** via the ESPHome **native API** (canonical source of truth), and
- an **MQTT broker** via the ESPHome **`mqtt:`** component (for the other consumers).

In scope: wiring, BOM, ESPHome config, SOPS secrets workflow, toolchain install,
USB first-flash, OTA, HA + MQTT integration, validation, rollback, repeatable layout
for future nodes. Out of scope (deferred, see §11): deep sleep, `web_server`,
additional sensors.

## 2. Bill of materials

| Item | Spec | Notes |
|------|------|-------|
| WeMos/LOLIN D1 mini | ESP8266EX, 4 MB flash, 3.3 V logic, USB-serial (CH340 typical; CP2104 on some clones) | **Not 5 V tolerant** |
| DHT22 / AM2302 | 3-pin **breakout module** (per D1) | Onboard pull-up present → `pullup: false` |
| Jumper wires | 3× female-female (or as needed) | DATA run **< ~1 m** for reliability |
| USB cable + supply | data-capable cable, **≥ 500 mA** 5 V | Undersized supply → Wi-Fi-TX brownout resets |

> **Sensor-quality note (Devil's Advocate):** the DHT22 is intentionally kept per
> requirement, but it is a mediocre sensor (±0.5 °C, slow, periodic NaN dropouts, no
> I²C). For *future* nodes, **SHT3x / BME280 / AHT20** (I²C — the D1/D2 bus we leave
> free) are superior drop-ins. This is a note, not a change.

## 3. Wiring

D1 mini logic is **3.3 V**. Power the sensor from **3V3** so the DATA line idles at
3.3 V (the board is not 5 V tolerant). DATA pin = **D5 / GPIO14** — a non-strapping,
boot-neutral GPIO that keeps the I²C bus (D1/D2) free and avoids the onboard LED
(D4/GPIO2). *(Verified by Embedded SME + Fact Checker against wemos.cc / pinout refs.)*

```
DHT22 breakout            D1 mini
┌──────────┐
│  +  / VCC │──────────────  3V3
│  out/DATA │──────────────  D5  (GPIO14)
│  -  / GND │──────────────  G  (GND)
└──────────┘
   (onboard pull-up on the module → no external resistor)
```

**Pin-safety reference (do NOT use for the sensor):** GPIO0/D3, GPIO2/D4,
GPIO15/D8 are strapping pins (gate boot); GPIO6–11 are tied to onboard flash;
GPIO1/3 are the UART. GPIO16/D0 has no interrupt/PWM. Full map:
D0=16, D1=5, D2=4, D3=0, D4=2(LED, active-LOW), D5=14, D6=12, D7=13, D8=15.

> If a future build uses a **bare 4-pin** DHT22 instead: add an external **4.7 kΩ**
> resistor DATA→3.3 V and set `pullup: true` (or rely on the external resistor and
> leave `pullup: false`). Not needed for the current breakout module (D1).

## 4. Repository layout

`Sensors/` is a **device-class grouping**, not a physical host, so it does not
disturb the repo's host-mapping convention (documented in the project README).

```
Sensors/Temperature/
├── README.md                  # quickstart: install, decrypt, flash, OTA
├── .gitignore                 # ignores secrets.yaml + .esphome/ build cache
├── secrets.yaml               # GITIGNORED, plaintext PLACEHOLDERS for now (SOPS later)
├── secrets.yaml.example       # COMMITTED, documents required keys (no real values)
├── .sops.yaml                 # (DEFERRED) age recipients once a key exists
├── secrets.sops.yaml          # (DEFERRED) committed encrypted copy, added later
├── scripts/
│   ├── decrypt-secrets.sh     # (DEFERRED) sops -d secrets.sops.yaml > secrets.yaml
│   └── flash.sh               # esphome run <node> (+ decrypt step once SOPS lands)
├── common/
│   ├── dht22-node.yaml        # shared package: all logic (wifi/api/mqtt/ota/dht)
│   └── secrets.yaml           # RELAY so `!secret` resolves from common/ (see §6)
├── nodes/
│   └── temp-living-room.yaml  # thin per-node file: substitutions + package include
└── docs/
    ├── team/ …                # team docs + notes
    └── plan/implementation-plan.md
```

Adding a node later = copy one ~12-line file in `nodes/` and change substitutions.

## 5. ESPHome configuration

### 5.1 Shared package — `common/dht22-node.yaml`

Uses **substitutions** (per-node values) and **`!secret`** (credentials). Lists in
ESPHome `packages:` deep-merge, so a node can append sensors without clobbering.

> **`!secret` path resolution (Round-1 fix):** ESPHome resolves `!secret` relative
> to the directory of the file **containing the tag** — here `common/`, not the
> entrypoint `nodes/` dir. So `common/` needs its own `secrets.yaml`. We do **not**
> duplicate secrets: `common/secrets.yaml` is a one-line relay —
> `<<: !include ../secrets.yaml` — pointing at the single root `secrets.yaml`.
> Per-node files use only `substitutions:` (no `!secret`), so `nodes/` needs none.

```yaml
# common/dht22-node.yaml — shared logic for every DHT22 temperature node
substitutions:
  node_name: temp-node          # overridden per node
  friendly_name: "Temp Node"    # overridden per node
  dht_pin: "D5"                 # GPIO14 — standardized (do NOT use D4)
  update_interval: "60s"

esphome:
  name: ${node_name}
  friendly_name: ${friendly_name}

esp8266:
  board: d1_mini

logger:                          # default level INFO; UART logging

# --- Home Assistant native API (canonical source of truth) ---
api:
  encryption:
    key: !secret api_encryption_key
  # MQTT is enabled below; reboot_timeout:0s prevents the 15-min reboot loop
  # that triggers when MQTT is on but no native-API client is connected.
  reboot_timeout: 0s

ota:
  - platform: esphome
    password: !secret ota_password

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  # Fallback AP + captive portal = OTA-failure safety net (headless recovery)
  ap:
    ssid: "${node_name} fallback"
    password: !secret fallback_ap_password

captive_portal:

# --- MQTT second output (for non-HA consumers) ---
mqtt:
  broker: !secret mqtt_broker
  port: 1883
  username: !secret mqtt_username
  password: !secret mqtt_password
  topic_prefix: sensors/temperature/${node_name}
  discovery: false              # HA gets entities via the native API, not MQTT
  # birth/will (LWT) default to retained <topic_prefix>/status = online/offline
  # → consumers MUST gate on status==online to avoid trusting a stale retained value

sensor:
  - platform: dht
    model: DHT22                # set explicitly; do not rely on auto
    pin: ${dht_pin}
    update_interval: ${update_interval}
    temperature:
      name: "${friendly_name} Temperature"
      filters:
        - filter_out: nan       # drop sensor dropouts before they propagate
    humidity:
      name: "${friendly_name} Humidity"
      filters:
        - filter_out: nan
```

### 5.2 Per-node file — `nodes/temp-living-room.yaml`

```yaml
packages:
  base: !include ../common/dht22-node.yaml

substitutions:
  node_name: temp-living-room
  friendly_name: "Living Room"
  # dht_pin / update_interval inherit the package defaults unless overridden
```

> **Pin consistency fix (Devil's Advocate #3):** the standardized DHT pin is
> **D5/GPIO14** everywhere. Any `D4` example is struck — D4 is GPIO2, a strapping
> pin and the onboard LED.

## 6. Secrets (decision D3 — SOPS target, placeholder interim)

ESPHome reads `secrets.yaml` **plaintext at compile time**. The chosen end-state is
SOPS+age (matching the monorepo), but **this workstation has no age key yet
(operator, 2026-06-14)**, so we proceed in two stages.

**Interim (now):**
- `secrets.yaml` — **gitignored**, holds **placeholder** values so `esphome config`
  validates and the layout is exercised. The operator fills in real values locally;
  they are never committed.
- `secrets.yaml.example` — **committed**, lists every required key with placeholder
  values (no real secrets). Keys: `wifi_ssid`, `wifi_password`,
  `fallback_ap_password`, `api_encryption_key`, `ota_password`, `mqtt_broker`,
  `mqtt_username`, `mqtt_password`.
- `.gitignore` ignores `secrets.yaml` and `.esphome/` (the relay `common/secrets.yaml`
  contains no values — only `<<: !include ../secrets.yaml` — so it is committed).
- Generate real values once available: `api_encryption_key` via
  `openssl rand -base64 32`; OTA/AP passwords via any strong generator.

**Deferred (once an age key exists on the workstation):**
- Add `.sops.yaml` with the operator age recipient (public key from
  `~/.config/sops/age/keys.txt`), commit an encrypted `secrets.sops.yaml`, and add
  `scripts/decrypt-secrets.sh` that runs `sops --decrypt secrets.sops.yaml >
  secrets.yaml` before each `esphome run`. The plaintext `secrets.yaml` stays
  gitignored throughout, so this migration is drop-in.
- **Exact step-by-step procedure** for the agent with the age key:
  [`../runbooks/deploy-and-sops-handoff.md`](../runbooks/deploy-and-sops-handoff.md) Part B.

> **Belt-and-suspenders (Devil's Advocate #4):** regardless of stage, add a
> pre-commit grep guard that hard-fails if a plaintext `secrets.yaml` with real
> values is ever staged, so a stray `git add -f` can't leak credentials.

## 7. Toolchain — ESPHome CLI via pipx (decision D2)

```bash
# Install (Debian/Ubuntu/Pop!_OS)
sudo apt install -y pipx && pipx ensurepath
pipx install esphome
esphome version          # confirm install

# USB serial prereqs (CH340/CP2104 drivers are in-kernel on modern Linux)
sudo usermod -aG dialout "$USER"     # log out/in for group to take effect
# If the port never appears: `sudo apt remove brltty` (it grabs CH340 adapters)
ls -l /dev/ttyUSB0                   # confirm the adapter enumerated
```

Docker alternative (not chosen, for reference): `docker run --rm -v "$PWD":/config
--device=/dev/ttyUSB0 -it esphome/esphome run nodes/temp-living-room.yaml`.

## 8. First flash (USB) and subsequent OTA

```bash
# Interim (placeholder/plaintext secrets.yaml already present):
esphome run nodes/temp-living-room.yaml   # prompts: pick /dev/ttyUSB0 for first flash
# Once SOPS lands, prepend the decrypt step:
#   ./scripts/decrypt-secrets.sh && esphome run nodes/temp-living-room.yaml
```

- The D1 mini has **auto-reset** — no manual flash-button dance.
- ESPHome compiles, flashes over USB, then opens serial logs. Confirm Wi-Fi
  connect, API server start, MQTT connect, and the first non-NaN reading.
- **Subsequent flashes go OTA**: re-run `esphome run nodes/temp-living-room.yaml`
  and choose the **OTA / network** target (uses `ota: password`).
- **OTA discipline (headless safety):** one change at a time; the ESP8266 under
  `kernelboot`-style flashing has no boot menu, so a bad OTA = a physical re-flash
  trip. The `ap:` + `captive_portal:` fallback is the recovery net.

## 9. Integration

### 9.1 Home Assistant (native API — canonical)
- HA auto-discovers the device via mDNS (Settings → Devices & Services → ESPHome,
  up to ~5 min), or add manually by `${node_name}.local` / IP. Supply the
  `api_encryption_key`.
- Entities: `sensor.<friendly>_temperature` (device_class temperature, °C,
  state_class `measurement`) and `_humidity` (%). `state_class: measurement` enables
  HA long-term statistics automatically.

### 9.2 MQTT (second output for other consumers)
- State topics: `sensors/temperature/${node_name}/sensor/<name>/state`, where
  `<name>` is the **slugified** sensor name (e.g. `living-room-temperature`,
  `living-room-humidity`) — what consumers subscribe to.
- Status/LWT: retained `sensors/temperature/${node_name}/status` = `online`/`offline`.
- `discovery: false` so HA does **not** create duplicate MQTT entities — HA's copy
  comes from the native API (the canonical source). *(Resolves Devil's Advocate #1.)*
- **Canonical-entity rule:** dashboards/automations in HA use the **API** entities;
  external consumers (Node-RED/Grafana/scripts) read the MQTT topics and **must gate
  on `status == online`** to avoid trusting a stale retained reading.
  *(Resolves Devil's Advocate #1 & #7.)*

## 10. Validation checklist

- [ ] `esphome config nodes/temp-living-room.yaml` validates after decrypt.
- [ ] USB flash completes; serial shows Wi-Fi + API + MQTT all up.
- [ ] First temperature/humidity readings are non-NaN and plausible.
- [ ] HA shows the device + 2 entities with correct units/device_class/statistics.
- [ ] `mosquitto_sub -t 'sensors/temperature/#' -v` shows state + retained `status`.
- [ ] Power-cycle: `status` flips offline→online via LWT; readings resume.
- [ ] OTA re-flash succeeds over the network.
- [ ] `git status` shows **no** plaintext `secrets.yaml` and **no** `.esphome/`.

## 11. Deferred / future (avoid gold-plating)

Deep sleep (battery nodes), `web_server` (**off on ESP8266** — documented RAM/
stability cost while API+MQTT are both active), additional/better sensors
(SHT3x/BME280/AHT20 on I²C), multi-node fan-out (the layout already supports it).

## 12. Open risks (tracked, not blocking)

- DHT22 NaN dropouts (mitigated by `filter_out: nan`, but a *persistent* failure
  shows as a gap — acceptable, and better than a frozen retained lie).
- Clone USB-serial chip variance (CH340 vs CP2104) — both in-kernel; only matters
  if the port doesn't enumerate (see §7).
- `esphome/issues#3695` (broker unreachable at boot) — Fact-Checker UNVERIFIED;
  `reboot_timeout: 0s` + API-canonical design limits blast radius. Revisit if seen.
