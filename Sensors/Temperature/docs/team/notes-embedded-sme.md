# Embedded SME — ESP8266/ESP32 Subject-Matter Expert

> Notes doc for the Temperature Sensor project. See [TEAM.md](./TEAM.md) for roles
> and protocol. This member is the sole writer of record for this file.

## Settled Knowledge

_(durable, verified facts accumulate here)_

### 1. WeMos / LOLIN D1 mini (ESP8266) board

**Core specs** (LOLIN official + community references):
- MCU: Espressif ESP8266EX. Operating voltage **3.3V — all IO pins are 3.3V logic, NOT 5V tolerant**.
- Flash: **4 MB** (4M Bytes). [LOLIN]
- USB-serial chip: **CH340** (newer V4.x boards use Type-C; older use micro-USB). Older revisions shipped CH340G; some clones use CP2104. [LOLIN docs link to a CH340 driver]
- 11 digital IO (interrupt / PWM / I2C / one-wire on all except D0); 1 analog input A0 (max 3.2V at the A0 header pin).
- Auto-reset: the CH340 + onboard DTR/RTS auto-reset circuit puts the ESP8266 into bootloader mode automatically. **No manual flash-button dance is required for the first USB flash.**

**Pin → GPIO mapping** (authoritative, confirmed across LastMinuteEngineers + RandomNerd + LOLIN):

| Label | GPIO | Notes |
|-------|------|-------|
| D0 | GPIO16 | No interrupt/PWM/I2C/one-wire; HIGH at boot; deep-sleep wake pin |
| D1 | GPIO5 | **Safe.** Default I2C SCL |
| D2 | GPIO4 | **Safe.** Default I2C SDA |
| D3 | GPIO0 | STRAPPING — boot FAILS if held LOW (FLASH button) |
| D4 | GPIO2 | STRAPPING — boot FAILS if held LOW; **onboard blue LED (active-LOW)** |
| D5 | GPIO14 | Safe. SPI SCK |
| D6 | GPIO12 | Safe. SPI MISO |
| D7 | GPIO13 | Safe. SPI MOSI |
| D8 | GPIO15 | STRAPPING — boot FAILS if held HIGH; has on-board pulldown |
| TX | GPIO1 | UART0 TX — serial console, avoid |
| RX | GPIO3 | UART0 RX — serial console, avoid |
| A0 | ADC0 | Analog only |

- **Onboard LED: GPIO2 (D4), active-LOW** (LOW = on). In ESPHome use `status_led` / `output` with `inverted: true`. Note: because the LED is on GPIO2, using D4 for a sensor and the status LED simultaneously conflicts.
- **Strapping/unsafe-to-use GPIOs:** GPIO0 (D3), GPIO2 (D4), GPIO15 (D8) — all gate boot. GPIO6–11 are wired to the SPI flash (never use). GPIO1/GPIO3 are the UART console.
- **Recommended DHT22 data GPIO: GPIO14 (D5).** Rationale: it is a fully general-purpose, non-strapping pin (boot-state-neutral), supports interrupts/one-wire timing, and avoids GPIO2/D4 (LED + strapping) and the I2C-default D1/D2 (reserved for future I2C peripherals). D1 (GPIO5) or D2 (GPIO4) are equally electrically safe; D5/GPIO14 is preferred here only to keep the I2C bus pins free.

### 2. DHT22 (AM2302) wiring

- **VCC: connect to 3.3V.** The DHT22 spec range is 3.3–6V, but the D1 mini logic is 3.3V and is NOT 5V tolerant, so powering the sensor from 5V would put a 5V data line on a 3.3V GPIO. Power from the D1 mini **3V3 pin** so the data line stays 3.3V.
- **GND → GND.** **DATA → chosen GPIO (D5 / GPIO14 recommended).**
- **Pull-up resistor: required, 4.7kΩ–10kΩ between DATA and VCC (3.3V).** Common value 4.7kΩ–5.1kΩ for short leads; 10kΩ acceptable.
  - **Bare 3-pin AM2302/DHT22 sensors need an external pull-up.**
  - **Most 3-pin breakout modules (the small PCB variants) already include the pull-up** (often 10kΩ or 1kΩ on the board). If the breakout has the resistor, do NOT add a second one, and set `pullup: false` in ESPHome on that pin.
- **Cable length:** keep DATA lead **< ~1m (≈3 ft)** with the standard pull-up for reliability; up to ~20m is possible per datasheet only with a lower-value pull-up and shielded/quality cable. Long runs are the #1 cause of NaN readings.

### 3. ESPHome `dht` platform

- `platform: dht`, `model: DHT22` (or `AM2302` — equivalent). `pin:` is **required**. Default `update_interval: 60s`.
- **Always set `model:` explicitly** — auto-detect is unreliable and a known source of NaN/wrong readings.
- For breakout boards with an onboard pull-up, configure the pin with `pullup: false`.
- **Do not poll too fast:** the DHT22 minimum sampling interval is ~2s; keep `update_interval` >= 30–60s (60s recommended) to avoid timing-related NaN.
- NaN-reading causes (in order): missing/weak pull-up, long/noisy cable, too-fast polling, wrong/auto model, marginal power.
- Recommended filtering: add a `filters:` block (e.g. `filter_out: nan` and/or `sliding_window_moving_average`) on temperature/humidity to suppress transient NaN spikes to HA/MQTT.

### 4. Flashing toolchain (ESP8266 + ESPHome)

- **CH340 driver on Linux:** the `ch341`/`ch340` kernel module ships with modern Linux (Ubuntu/Pop!_OS) — usually no install needed. The board enumerates as **`/dev/ttyUSB0`**.
  - Add your user to the **`dialout`** group for non-root serial access: `sudo usermod -aG dialout $USER` (log out/in).
  - Known gotcha: the **`brltty`** package can grab CH340 USB serial devices on some distros — if `/dev/ttyUSB0` disappears, `sudo apt remove brltty`.
- **First flash = USB** (auto-reset handles bootloader entry; no button press):
  - `pip install esphome` then `esphome run sensor-temp.yaml` (compiles + prompts for the serial port; pick `/dev/ttyUSB0`).
  - Or ESPHome dashboard → Install → "Plug into this computer", or web flasher (esphome-web / web.esphome.io via Chrome WebSerial).
  - Raw esptool fallback: `esptool.py --port /dev/ttyUSB0 --baud 460800 write_flash 0x0 firmware-factory.bin`.
- **Subsequent flashes = OTA** (wireless). Enable the `ota:` component in YAML; after the first USB flash, `esphome run sensor-temp.yaml` auto-detects the device on the network and uploads OTA. No USB needed again.

### 5. Power

- **Power via USB (5V):** the onboard regulator drops 5V→3.3V; this is the simplest and recommended bench/deploy option. USB 5V also reaches the `5V` header pin.
- **Power via 3V3 pin:** feed a clean regulated 3.3V directly to the 3V3 pin (bypasses the onboard regulator). Do NOT feed 5V into 3V3.
- **Current draw:** ESP8266 averages ~70–80mA, with Wi-Fi TX peaks up to ~300–500mA briefly. The DHT22 adds only ~1–1.5mA active. Total well within a normal USB port.
- **Brownout:** Wi-Fi TX current spikes can cause resets on weak USB cables / underpowered supplies. Use a good USB cable and a supply rated >= 500mA. A 100µF+ bulk capacitor across 3V3/GND helps if resets persist.

## Working Notes

### 2026-06-14 — Embedded SME research pass

- Verified D1 mini GPIO map against three independent references (LastMinuteEngineers, RandomNerdTutorials, LOLIN official). All agree: D0=GPIO16, D1=GPIO5, D2=GPIO4, D3=GPIO0, D4=GPIO2, D5=GPIO14, D6=GPIO12, D7=GPIO13, D8=GPIO15, TX=GPIO1, RX=GPIO3.
- LOLIN official page (wemos.cc) confirms 4MB flash, 3.3V logic, 3.2V A0 max, "11 digital IO (except D0)" for I2C/one-wire/PWM — it does NOT print the GPIO table in text, so GPIO numbers are cross-sourced from the community refs above (consistent and long-standing for this board).
- Strapping-pin behavior (GPIO0 boot-fail-if-LOW, GPIO2 boot-fail-if-LOW, GPIO15 boot-fail-if-HIGH) confirmed by RandomNerd + kevinstadler boot-state notes. These three plus GPIO6–11 (flash) and GPIO1/3 (UART) are the "avoid" set.
- DHT22 model value: ESPHome docs accept both `DHT22` and `AM2302`; pull-up ~4.7k to 3.3V, `pullup: false` for breakout modules — confirmed on esphome.io/components/sensor/dht.html.
- Chose GPIO14/D5 for DHT data to leave I2C (D1/D2) free; D1/D2 would be electrically fine too. Flagged the D4/GPIO2 LED-vs-sensor conflict for the team.

### 2026-06-14 — Round 1 vote on implementation-plan.md

**VOTE: YAE**

Reviewed `docs/plan/implementation-plan.md` from the ESP8266/DHT22 hardware lens.
Every embedded-critical detail matches my Settled Knowledge; no wrong pin, wrong
voltage, or wrong flash command.

- Wiring correct: VCC→3V3 (not 5V — board not 5V-tolerant), DATA→D5/GPIO14, GND→GND.
  Pin-safety table in §3 matches my GPIO map exactly (strapping GPIO0/2/15, flash
  GPIO6–11, UART GPIO1/3; D4/GPIO2 = active-LOW LED). D5/GPIO14 is the right choice
  (non-strapping, boot-neutral, leaves I²C D1/D2 free).
- `pullup: false` correct for the 3-pin breakout (D1) — onboard pull-up, no external
  4.7k. The §3 bare-4-pin fallback note (add 4.7kΩ + `pullup: true`) is also right.
- `dht` platform correct: explicit `model: DHT22`, `update_interval: 60s` (well above
  the ~2s floor), `filter_out: nan` on temp + humidity.
- Toolchain/flash correct: pipx, `dialout` + logout, `brltty` removal gotcha,
  `/dev/ttyUSB0`, CH340/CP2104 in-kernel, auto-reset (no button dance), USB-first then
  OTA, `ap:`+`captive_portal:` recovery net. Power §2/BOM correct (≥500mA, brownout risk).
- NIT (non-blocking): `api: reboot_timeout: 0s` is a correct and necessary addition
  beyond my notes — with `mqtt:` on and no native-API client connected, ESPHome's
  default 15-min API reboot_timeout would reboot-loop the device. Good catch; not an
  embedded defect.
- NIT (non-blocking): §12 cites esphome issue #3695 as UNVERIFIED — fine to track as a
  risk; `reboot_timeout: 0s` already limits the blast radius.

**Sources:**
- LOLIN D1 mini official: https://www.wemos.cc/en/latest/d1/d1_mini.html
- ESPHome DHT sensor: https://esphome.io/components/sensor/dht.html
- ESP8266 GPIO reference (strapping/safe pins, LED on GPIO2): https://randomnerdtutorials.com/esp8266-pinout-reference-gpios/
- D1 mini pinout (GPIO map, I2C SDA=GPIO4/SCL=GPIO5): https://lastminuteengineers.com/wemos-d1-mini-pinout-reference/
- D1 mini boot/reset pin states: https://kevinstadler.github.io/notes/esp8266-wemos-d1-mini-pin-state-reset/
- ESPHome status_led (onboard LED active-LOW, inverted): https://esphome.io/components/light/status_led/
- ESPHome flashing guide / CH340 on Linux: https://www.binarytechlabs.com/how-to-flash-esphome-firmware-a-friendly-step-by-step-guide/
