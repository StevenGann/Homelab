# Temperature Sensors — D1 mini (ESP8266) + DHT22 → Home Assistant + MQTT

ESPHome firmware for WeMos/LOLIN **D1 mini** nodes that read a **DHT22 (AM2302)**
and publish temperature + humidity to **Home Assistant** (native API, canonical) and
an **MQTT broker** (for non-HA consumers).

> `Sensors/` is a **device-class grouping**, not a physical host — it does not change
> the repo's top-level host-mapping convention.

## Documents

- **Deploy & SOPS handoff runbook:** [`docs/runbooks/deploy-and-sops-handoff.md`](docs/runbooks/deploy-and-sops-handoff.md)
  — **start here to deploy.** Self-contained: Part A = flash a node, Part B = migrate
  secrets to SOPS+age (for the system that holds the age key).
- **Implementation plan:** [`docs/plan/implementation-plan.md`](docs/plan/implementation-plan.md)
  — vetted by the team (Round 1: **5 YAE / 0 NAY**).
- **Team & process:** [`docs/team/TEAM.md`](docs/team/TEAM.md) (roster, notes, voting).

## Hardware / wiring

DHT22 **breakout module** (onboard pull-up) → `pullup: false`, no external resistor.
The D1 mini is **3.3 V** logic (not 5 V tolerant); power the sensor from **3V3**.

```
DHT22 module        D1 mini
  VCC  ───────────── 3V3
  DATA ───────────── D5   (GPIO14 — non-strapping, leaves I2C free, not the LED pin)
  GND  ───────────── G
```

Use a data-capable USB cable on a **≥ 500 mA** supply (Wi-Fi TX peaks cause brownout
resets on weak supplies). Keep the DATA run under ~1 m.

## Layout

| Path | What |
|------|------|
| `common/dht22-node.yaml` | All shared logic (wifi/api/mqtt/ota/dht). Edit here. |
| `common/secrets.yaml` | Relay (`<<: !include ../secrets.yaml`) so `!secret` resolves from `common/`. No values. |
| `nodes/<name>.yaml` | Thin per-node file: substitutions + package include. Copy to add a node. |
| `secrets.yaml` | **gitignored** plaintext (placeholders now; SOPS later). |
| `secrets.yaml.example` | Committed template of required keys. |
| `scripts/flash.sh` | Convenience wrapper around `esphome run`. |

## Quickstart

```bash
# 1. Toolchain (once)
sudo apt install -y pipx && pipx ensurepath
pipx install esphome
sudo usermod -aG dialout "$USER"        # then log out/in
# if /dev/ttyUSB0 never appears: sudo apt remove brltty

# 2. Secrets
cp secrets.yaml.example secrets.yaml    # then edit real values (stays gitignored)
# api_encryption_key: openssl rand -base64 32

# 3. Validate
esphome config nodes/temp-living-room.yaml

# 4. First flash over USB (auto-reset; no button dance)
./scripts/flash.sh nodes/temp-living-room.yaml      # pick /dev/ttyUSB0

# 5. Subsequent updates go OTA — re-run the same command, choose the network target.
```

## Integration

- **Home Assistant:** auto-discovered via mDNS (Settings → Devices & Services →
  ESPHome) or add by `<node_name>.local`; supply `api_encryption_key`. Entities get
  `state_class: measurement` → long-term statistics.
- **MQTT:** state at `sensors/<location>/temperature` and `sensors/<location>/humidity`
  (e.g. `sensors/garage/temperature`); retained `sensors/<location>/status` =
  `online`/`offline` (LWT). `<location>` is the per-node `location` substitution.
  MQTT discovery is **off** (HA uses the API), so non-HA consumers read the topics
  directly and **must gate on `status == online`** to avoid stale retained values.
  (ESPHome retains state by default, so a subscriber gets the last value immediately;
  it refreshes every `update_interval`/60s. A retained value can be stale if a node
  died — that's exactly what the `status` gate is for.)

## Adding a node

Copy `nodes/temp-living-room.yaml`, change `node_name`/`friendly_name`, flash. That's it.

## Deferred (see plan §6, §11)

SOPS+age encryption of secrets (no age key on this workstation yet); deep sleep,
`web_server` (kept **off** on ESP8266 for stability), and better I2C sensors
(SHT3x/BME280/AHT20) for future nodes.
