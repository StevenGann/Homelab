# HA/MQTT SME — Home Assistant & MQTT Subject-Matter Expert

> Notes doc for the Temperature Sensor project. See [TEAM.md](./TEAM.md) for roles
> and protocol. This member is the sole writer of record for this file.

## Settled Knowledge

_(durable, verified facts accumulate here)_

### 1. Native API vs MQTT — CAN THEY COEXIST?

**Definitive answer: YES, `api:` and `mqtt:` can both be enabled simultaneously on
the same ESP8266.** They are independent ESPHome components. ESPHome's own MQTT docs
describe a both-enabled configuration as a supported pattern. There is, however, ONE
load-bearing gotcha that bites almost everyone:

- **The native API (`api:`) is the recommended path for Home Assistant integration.**
  The API docs state it "offers many advantages over using MQTT" (efficiency,
  stability, low latency). MQTT "will never be removed" but is positioned as the
  secondary/alternative protocol.
  Source: https://esphome.io/components/api/

- **THE REBOOT TRAP (must handle for this dual-publish project):** The MQTT docs say
  verbatim: *"If you enable MQTT and you do not use the [Api], you must remove the
  `api:` configuration or set `reboot_timeout: 0s`, otherwise the ESP will reboot
  every 15 minutes because no client connected to the native API."*
  The `api:` component's `reboot_timeout` defaults to **15min** and is "the amount of
  time to wait before rebooting when no client connects to the API"; disable with `0s`.
  Sources: https://esphome.io/components/mqtt/ , https://esphome.io/components/api/

  => For THIS project (publish to BOTH HA via API AND to an MQTT broker), keep `api:`
  enabled. If Home Assistant is actively connected to the API, the API client keeps
  the timeout satisfied and no reboot occurs. **If you are NOT certain HA will always
  be connected to the API (e.g. MQTT-only consumers, HA down for maintenance), set
  `api: reboot_timeout: 0s` to be safe.** This is the single most important config
  decision for a dual-publish device.

- **Setup-blocking caveat:** A known issue (esphome/issues#3695) — if the device
  cannot connect to the MQTT broker, `setup()` may not finish, which can also block
  the API path. Mitigate by ensuring broker reachability or testing failure modes.
  Source: https://github.com/esphome/issues/issues/3695

- **Avoid duplicate entities:** When both API and MQTT discovery are on, HA can get
  the same entity twice (via the ESPHome integration AND via MQTT discovery), causing
  "Entity id already exists" / duplicate-cleanup pain. If HA connects via the API,
  set `mqtt: discovery: false` so HA's copy comes only from the API, and the broker
  still receives raw state topics for non-HA MQTT consumers. ESPHome also offers
  `mqtt: discover_ip:` which lets HA find the device's IP over MQTT while still using
  the native API — in that case MQTT discovery is redundant and should be off.
  Sources: https://esphome.io/components/mqtt/ ,
  https://community.home-assistant.io/t/having-both-the-home-assistant-api-and-mqtt-configured/215069

  NOTE / nuance for the Fact Checker: community threads frequently say "don't run
  both, pick one." That advice is about avoiding the reboot loop and duplicate
  entities, NOT a claim that it's technically impossible. It IS possible and
  supported; the project requirement (both HA + a separate broker) is exactly the
  case where you intentionally run both, with the two guards above.

### 2. Home Assistant discovery — two independent mechanisms

- **Native API discovery (recommended):** After adding `api:`, ESPHome devices are
  auto-discovered by the Home Assistant ESPHome integration (mDNS). Per the docs:
  go to Settings → Devices & Services / Integrations and wait for the device under
  "discovered" (up to ~5 min), OR add manually via the ESPHome integration entering
  `<NODE_NAME>.local` or the IP in the Host field. No MQTT infrastructure needed.
  Source: https://esphome.io/components/api/

- **MQTT discovery (separate path):** ESPHome's `mqtt:` block publishes Home Assistant
  MQTT-discovery config messages when `discovery: true` (default) under the
  `discovery_prefix` (default `homeassistant`). HA's MQTT integration then creates the
  entities. `discovery_retain` defaults to `true`. This requires HA's MQTT integration
  + a broker, and is the path to use if you deliberately want HA to consume the device
  via MQTT instead of the API.
  Source: https://esphome.io/components/mqtt/

  For this project: pick the API path for HA (better), and keep MQTT purely for the
  external broker — so set `mqtt: discovery: false` to avoid the double-entity issue.

### 3. MQTT component specifics (verified against esphome.io/components/mqtt/)

- `broker` (required), `port` (default **1883**), `username`, `password`
  (use `!secret`), `client_id` (auto from device name + MAC), `topic_prefix`
  (defaults to the device name).
- **Default topic structure:** `<topic_prefix>/<component_type>/<component_name>/state`
  e.g. `temperature-sensor/sensor/temperature/state`.
- **Birth / will (LWT):** default retained messages to `<topic_prefix>/status` with
  payload `online` (birth) and `offline` (will / Last-Will-and-Testament). Configurable
  via `birth_message` / `will_message`.
- **`retain`** default **true** (state messages retained). **`discovery_retain`** default
  **true**. **QoS** defaults to **0** for publishing (per-message configurable).
- **`reboot_timeout`** ALSO exists on the `mqtt:` component (reboot when MQTT
  disconnects) — distinct from the `api:` one. `clean_session` default false.
  Source: https://esphome.io/components/mqtt/

  Concrete snippet (sources above):
  ```yaml
  mqtt:
    broker: 192.168.10.x          # your broker
    port: 1883
    username: !secret mqtt_user
    password: !secret mqtt_password
    topic_prefix: temperature-sensor
    discovery: false              # HA gets entities via the native API, not MQTT
    birth_message:                # optional explicit LWT/birth
      topic: temperature-sensor/status
      payload: online
    will_message:
      topic: temperature-sensor/status
      payload: offline
    # retain defaults true; QoS defaults 0
  ```

### 4. DHT22 sensor exposure in Home Assistant

- DHT22 == AM2302. Use `platform: dht`, `model: AM2302`, with `temperature:` and
  `humidity:` sub-sensors, each given a `name` (and recommended `id`), a `pin`, and
  `update_interval` (default 60s if omitted). 4.7kΩ pull-up required on DATA→3.3V.
  Source: https://esphome.io/components/sensor/dht.html
- ESPHome's DHT temperature sensor ships sensible HA metadata by default:
  device_class `temperature`, unit `°C`, state_class `measurement`; humidity ships
  device_class `humidity`, unit `%`, state_class `measurement`. `state_class:
  measurement` is what enables HA long-term statistics. (humidity defaults
  `accuracy_decimals: 0` — bump to 1 for finer resolution.) These are overridable per
  sub-sensor (`device_class:`, `unit_of_measurement:`, `state_class:`,
  `accuracy_decimals:`).
  Source: https://esphome.io/components/sensor/dht.html (+ sensor base component)

  Concrete snippet:
  ```yaml
  sensor:
    - platform: dht
      pin: D2
      model: AM2302
      temperature:
        name: "Temperature"
        id: dht_temperature
      humidity:
        name: "Humidity"
        id: dht_humidity
        accuracy_decimals: 1
      update_interval: 60s
  ```

### 5. OTA, dashboard, web_server, wifi/secrets

- **ESPHome dashboard / add-on:** ESPHome is normally run as the HA add-on (or
  standalone dashboard); it compiles and flashes firmware. After the first USB flash,
  subsequent updates go over the network.
- **OTA:** add the `ota:` component (platform `esphome`) to enable wireless firmware
  updates from the dashboard. Source: https://esphome.io/components/ota/
- **`web_server` (optional):** local browser UI + REST API, default port 80, UI
  versions 1/2/3 (v2 default; v3 adds entity grouping/graphing). WARNING from the docs:
  "enabling this component will take up a lot of memory and may decrease stability,
  especially on ESP8266." On a D1 mini, enable only if you really want the local UI;
  it competes for RAM with API+MQTT+TLS. Source: https://esphome.io/components/web_server.html
- **WiFi + secrets + fallback:** put SSID/password in `wifi:` using `!secret`; add an
  `ap:` fallback hotspot + `captive_portal:` so the device serves a config portal if it
  can't join WiFi. Source: https://esphome.io/components/wifi.html ,
  https://esphome.io/components/captive_portal.html

## Working Notes

### 2026-06-14 — research pass (HA/MQTT SME)

- Researched all 5 task areas live against esphome.io + HA community. Central question
  (api + mqtt coexistence) cross-checked across THREE sources: ESPHome MQTT docs,
  ESPHome API docs, and the HA community thread. They agree on the mechanics; they
  differ only in tone (community says "usually pick one"), which I reconciled in the
  Settled Knowledge note — coexistence is supported and is exactly our use case.
- Key engineering takeaway for the plan: keep `api:` for HA, add `mqtt:` for the
  external broker, set `mqtt: discovery: false`, and decide `api: reboot_timeout`
  (leave default 15min ONLY if HA is reliably connected via API; otherwise `0s`).
- Open item for Embedded SME / Senior Dev: confirm RAM headroom on the D1 mini
  (ESP8266) with API + MQTT both active; the web_server docs explicitly warn about
  ESP8266 memory. Recommend leaving web_server OFF unless needed.
- Sources for Fact Checker (all fetched 2026-06-14):
  - https://esphome.io/components/api/
  - https://esphome.io/components/mqtt/
  - https://esphome.io/components/sensor/dht.html
  - https://esphome.io/components/web_server.html
  - https://esphome.io/components/ota/
  - https://esphome.io/components/wifi.html
  - https://esphome.io/components/captive_portal.html
  - https://github.com/esphome/issues/issues/3695
  - https://community.home-assistant.io/t/having-both-the-home-assistant-api-and-mqtt-configured/215069

### 2026-06-14 — Round 1 vote (HA/MQTT SME)

**VOTE: YAE.** The implementation plan correctly handles every item in my lens.

- **api+mqtt coexistence:** both components enabled = the supported dual-publish
  pattern. Correct for D4 (real non-HA consumers exist).
- **`api: reboot_timeout: 0s`:** VERIFIED correct. The 15-min reboot loop fires
  when MQTT is on AND no native-API client is connected. `0s` disables the timeout
  unconditionally, so the device survives HA being down/disconnected while still
  serving MQTT-only consumers. This is the conservative choice my Settled Knowledge
  note prescribes — exactly right here.
- **`discovery: false`:** prevents HA double-creating entities (ESPHome API
  integration + MQTT discovery). HA's copy comes only from the native API. No
  duplicate-entity risk.
- **Birth/will/LWT + retain + status-gating:** plan documents default retained
  `<topic_prefix>/status` = online/offline and — critically — instructs external
  consumers to gate on `status == online` so a stale retained reading is never
  trusted. Resolves the stale-retained-data trap. `retain` default true acknowledged.
- **device_class/state_class:** `temperature`/°C/`measurement` + humidity %/`measurement`;
  `state_class: measurement` enables HA long-term statistics. Matches ESPHome DHT
  defaults — consistent with reality.
- **OTA + wifi `!secret` + ap/captive_portal:** `ota: esphome` with `!secret`,
  wifi via `!secret`, fallback AP + captive portal recovery net. All correct.
- **NIT (non-blocking):** §9.2 state-topic example `<topic_prefix>/sensor/<name>/state`
  uses `<name>` = the *slugified* sensor name (e.g. `living-room-temperature`), not a
  clean `temperature`/`humidity`. Matches the ESPHome default scheme, but a one-line
  note that `<name>` is the slug would help consumers writing subscriptions. Doc
  precision only — not a defect.
- **NIT:** `esphome/issues#3695` (broker-unreachable-at-boot may block setup) remains
  Fact-Checker-UNVERIFIED; `reboot_timeout: 0s` + API-canonical design limits blast
  radius. Already tracked in §12 — acceptable to ship and revisit if seen.
