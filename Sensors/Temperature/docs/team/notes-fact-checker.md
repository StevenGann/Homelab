# Fact Checker — Verification

> Notes doc for the Temperature Sensor project. See [TEAM.md](./TEAM.md) for roles
> and protocol. This member is the sole writer of record for this file.
>
> Method: extracted concrete assertions from notes-senior-dev.md,
> notes-embedded-sme.md, notes-ha-mqtt-sme.md; confirmed each against
> authoritative sources (esphome.io, home-assistant.io, vendor pinout refs,
> AM2302 datasheets). All verifications performed 2026-06-14.

## Settled Knowledge

_(verdicts — CONFIRMED / DENIED / PARTIAL, one source each)_

### D1 mini hardware (Embedded SME)

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 1 | D0=GPIO16 | **CONFIRMED** | LastMinuteEngineers map. <https://lastminuteengineers.com/wemos-d1-mini-pinout-reference/> |
| 2 | D1=GPIO5 (I2C SCL) | **CONFIRMED** | LME: "GPIO5 (SCL)". Same source. |
| 3 | D2=GPIO4 (I2C SDA) | **CONFIRMED** | LME: "GPIO4 (SDA)". Same source. |
| 4 | D3=GPIO0 | **CONFIRMED** | Same source. |
| 5 | D4=GPIO2 | **CONFIRMED** | Same source. |
| 6 | D5=GPIO14 | **CONFIRMED** | Same source. |
| 7 | D6=GPIO12 | **CONFIRMED** | Same source. |
| 8 | D7=GPIO13 | **CONFIRMED** | Same source. |
| 9 | D8=GPIO15 | **CONFIRMED** | Same source. |
| 10 | TX=GPIO1, RX=GPIO3, A0=ADC0 | **CONFIRMED** | Same source. |
| 11 | Strapping pins = GPIO0, GPIO2, GPIO15 gate boot | **CONFIRMED** | RandomNerd: GPIO0 boot-fail-if-LOW, GPIO2 high-on-boot/boot-fail-if-LOW, GPIO15 boot-fails-if-HIGH. <https://randomnerdtutorials.com/esp8266-pinout-reference-gpios/> |
| 12 | GPIO0 boot FAILS if LOW (D3 = FLASH button) | **CONFIRMED** | RandomNerd, same source. |
| 13 | GPIO2 (D4) boot FAILS if held LOW | **CONFIRMED** | RandomNerd: "high on BOOT, boot failure if pulled LOW." Same source. |
| 14 | GPIO15 (D8) boot FAILS if held HIGH; on-board pulldown | **CONFIRMED** | RandomNerd: "boot fails if pulled HIGH." Same source. |
| 15 | Onboard LED = GPIO2 (D4), active-LOW | **CONFIRMED** | RandomNerd: GPIO2 "connected to on-board LED," inverted logic. Same source. ESPHome status_led documents inverted/active-LOW. <https://esphome.io/components/light/status_led/> |
| 16 | GPIO6–11 wired to SPI flash (never use) | **CONFIRMED** | RandomNerd: "GPIO6 to GPIO11 are usually connected to the flash chip." Same source. |
| 17 | All IO is 3.3V logic, NOT 5V tolerant | **CONFIRMED** | LOLIN: operating voltage 3.3V. <https://www.wemos.cc/en/latest/d1/d1_mini.html> |
| 18 | 4 MB flash | **CONFIRMED** | LOLIN: "4M Bytes." Same source. |
| 19 | A0 max ≈3.2V at header | **CONFIRMED** | LOLIN: "3.2V Max." Same source. |
| 20 | 11 digital IO | **CONFIRMED** | LOLIN: "11." Same source. |
| 21 | USB-serial chip = CH340 | **PARTIAL** | LOLIN page links a "CH340 Driver" but does not print the chip name in the spec table; widely documented as CH340 for LOLIN boards; CP2104 on some clones is plausible but uncited here. Same source. |
| 22 | Recommended DHT22 pin = GPIO14/D5 | **CONFIRMED (as a recommendation)** | GPIO14 is non-strapping, non-flash, non-UART per #11/#16 — electrically valid. D1/D2 equally safe; D5 is a preference (frees I2C), not a hard requirement. Sources #1–#16 above. |

### DHT22 wiring & power (Embedded SME)

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 23 | DHT22 must be powered at 3.3V on the D1 mini (data line must stay 3.3V; MCU not 5V tolerant) | **CONFIRMED** | MCU not 5V tolerant (#17); a 5V-powered DHT22 drives a 5V data line into a 3.3V GPIO. Powering from 3V3 is the correct mitigation. <https://www.wemos.cc/en/latest/d1/d1_mini.html> + ESPHome DHT pull-up note "between DATA and 3.3V." <https://esphome.io/components/sensor/dht.html> |
| 24 | DHT22 spec voltage range is 3.3–6V | **PARTIAL** | Datasheets vary: Aosong/Adafruit AM2302 commonly cite **3.3–5.5V**; some list 3.3–6V. Direction right, upper bound source-dependent. <https://cdn-shop.adafruit.com/datasheets/Digital+humidity+and+temperature+sensor+AM2302.pdf> ; <https://components101.com/sensors/dht22-pinout-specs-datasheet> |
| 25 | Pull-up required, 4.7kΩ–10kΩ between DATA and VCC(3.3V) | **CONFIRMED** | ESPHome: "about 4.7kΩ (anything in the range from 1kΩ to 10kΩ probably works fine)" between DATA and 3.3V. <https://esphome.io/components/sensor/dht.html> |
| 26 | Bare 3-pin sensors need external pull-up; most breakout PCBs include one → set `pullup: false` | **CONFIRMED** | ESPHome documents `pullup: false` pin option to disable the internal pull-up; breakout-onboard pull-ups are standard. Same source. |
| 27 | Long DATA runs cause NaN; keep < ~1m with standard pull-up | **PARTIAL** | Widely reported field guidance, but not a hard spec figure on esphome.io. Same source. |

### ESPHome `dht` platform (Embedded SME + HA/MQTT SME)

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 28 | `model: DHT22` valid (and `AM2302` equivalent) | **CONFIRMED** | Accepted model values include DHT22 and AM2302. <https://esphome.io/components/sensor/dht.html> |
| 29 | `pin:` is required | **CONFIRMED** | Same source — pin marked required. |
| 30 | Default `update_interval` = 60s | **CONFIRMED** | Same source. |
| 31 | Always set `model:` explicitly (auto-detect unreliable) | **PARTIAL** | `AUTO_DETECT` is a documented value; "explicit is safer" is sound, but "auto-detect is unreliable" is advisory, not a documented warning. Same source. |
| 32 | Sub-sensor defaults: temp device_class=temperature/unit=°C/state_class=measurement; humidity device_class=humidity/unit=%/state_class=measurement; humidity accuracy_decimals=0 | **PARTIAL** | DHT page confirms humidity default `accuracy_decimals: 0`. It does NOT print the device_class/unit/state_class defaults on that page; those defaults are real but documented at sensor-base level, not quoted on the DHT page. <https://esphome.io/components/sensor/dht.html> |

### Native API + MQTT (HA/MQTT SME) — LOAD-BEARING

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 33 | `api:` and `mqtt:` CAN both be enabled simultaneously | **CONFIRMED** | ESPHome MQTT docs show a both-enabled configuration; the reboot-trap text presupposes `api:` present alongside `mqtt:`. <https://esphome.io/components/mqtt/> |
| 34 | Reboot trap: MQTT without using the API → reboot every 15 min; fix = remove `api:` or `api: reboot_timeout: 0s` | **CONFIRMED** | Verbatim MQTT docs: "If you enable MQTT and you do _not_ use the Api, you must remove the `api:` configuration or set `reboot_timeout: 0s`, otherwise the ESP will reboot every 15 minutes because no client connected to the native API." <https://esphome.io/components/mqtt/> |
| 35 | `api: reboot_timeout` default = 15 min | **CONFIRMED** | API docs: default 15min, "amount of time to wait before rebooting when no client connects to the API." <https://esphome.io/components/api/> |
| 36 | Native API is the recommended HA path; "offers many advantages over MQTT" | **CONFIRMED** | API docs list efficiency/setup/reliability/low-latency advantages. <https://esphome.io/components/api/> |
| 37 | Duplicate-entity risk with both API + MQTT discovery on; mitigate with `mqtt: discovery: false` | **CONFIRMED (mechanism) / PARTIAL (the specific fix)** | Duplicate entities real (community: "Entity id already exists"). MQTT discovery defaults `true`, so disabling it is the technically correct fix and the SME's reasoned recommendation — but the cited community thread itself recommends "pick one protocol," not `discovery: false`. The fix is sound; it is the SME's synthesis, not a verbatim doc instruction. <https://esphome.io/components/mqtt/> ; <https://community.home-assistant.io/t/having-both-the-home-assistant-api-and-mqtt-configured/215069> |
| 38 | MQTT setup-blocking caveat: if broker unreachable, setup() may not finish (esphome/issues#3695) | **UNVERIFIED** | Cited but not re-fetched this pass; low load-bearing. <https://github.com/esphome/issues/issues/3695> |

### MQTT component specifics (HA/MQTT SME)

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 39 | Default port 1883 | **CONFIRMED** | MQTT docs. <https://esphome.io/components/mqtt/> |
| 40 | `retain` default true | **CONFIRMED** | Same source. |
| 41 | `discovery` default true | **CONFIRMED** | Same source. |
| 42 | `discovery_retain` default true | **CONFIRMED** | Same source. |
| 43 | QoS default 0 | **CONFIRMED** | Same source. |
| 44 | Birth/will → retained `<TOPIC_PREFIX>/status`, payload `online`/`offline` | **CONFIRMED** | Same source (verbatim). |
| 45 | Topic structure `<prefix>/<component_type>/<component_name>/state` | **CONFIRMED** | Same source (verbatim). |

### web_server / secrets / packages (HA/MQTT SME + Senior Dev)

| # | Assertion | Verdict | Reason / Source |
|---|-----------|---------|-----------------|
| 46 | web_server "takes up a lot of memory and may decrease stability, especially on ESP8266" | **CONFIRMED** | Verbatim from web_server docs. <https://esphome.io/components/web_server.html> |
| 47 | web_server default port 80 | **CONFIRMED** | Same source. |
| 48 | gitignore secrets.yaml + commit secrets.yaml.example is idiomatic; `!secret` reads secrets.yaml in the same dir as the config | **CONFIRMED** | Standard ESPHome guidance; `!secret` resolves to local secrets.yaml. <https://esphome.io/guides/faq/> |
| 49 | `packages:` deep-merges (dicts key-by-key, lists concatenate) unlike `!include` raw splice | **CONFIRMED** | Packages docs: "Dictionaries are merged key-by-key. Lists of components are merged by component ID (if specified). Other lists are merged by concatenation." <https://esphome.io/components/packages/> |
| 50 | Remote packages CANNOT use `!secret`; must use substitutions | **CONFIRMED** | Packages docs (verbatim): "Remote packages cannot have `secret` lookups in them. They should instead make use of substitutions…" <https://esphome.io/components/packages/> |

## Working Notes

### 2026-06-14 — verification pass

- Fetched all primary sources directly (esphome.io api/mqtt/dht/web_server/packages,
  wemos.cc D1 mini, LastMinuteEngineers + RandomNerd pinouts, HA community thread,
  AM2302 datasheets). 50 assertions extracted and adjudicated.
- The three load-bearing claims (pin map, 4.7k pull-up, api+mqtt coexistence +
  reboot gotcha) all CONFIRMED against authoritative docs, verbatim where binding.
- Contradictions and weak spots captured below.

#### Contradictions / discrepancies found

1. **Reboot interval: 15 min vs 5 min.** The HA/MQTT SME cites "reboot every 15
   minutes" — CORRECT per the official ESPHome MQTT and API docs (reboot_timeout
   default 15min). The cited HA community thread says "every 5 minutes." The
   official docs win; the SME's 15-min figure is the right one to carry. Worth a
   note so nobody trusts the community thread's number.

2. **api+mqtt coexistence — tone vs mechanics.** The community thread concludes
   "coexistence isn't supported in practice — pick one." The HA/MQTT SME correctly
   reconciled this: coexistence IS supported by ESPHome (docs show both enabled),
   and the community advice is really about avoiding the reboot loop + duplicate
   entities. The SME's synthesis is sound; flagging only that the raw community
   source is more negative than the SME's framing.

3. **`mqtt: discovery: false` as the duplicate-entity fix.** Verdict #37: the fix
   is technically correct (discovery defaults true), but it is the SME's reasoned
   recommendation, NOT a verbatim instruction from the cited thread (which says
   "pick one"). Good engineering, just not a direct quote — implement it, don't
   attribute it to the thread.

#### Could-not-verify / weakened claims

- #38 esphome/issues#3695 (MQTT broker unreachable blocking setup) — UNVERIFIED.
- #21 CH340 chip name — PARTIAL (not in LOLIN spec table; clones vary).
- #24 DHT22 "3.3–6V" — PARTIAL; most AM2302 datasheets say 3.3–5.5V. Does not
  affect the design (we power at 3.3V regardless).
- #27 "<1m cable" and #31 "auto-detect unreliable" — PARTIAL; sound field
  guidance, not documented specs/warnings.
- #32 temp/humidity device_class/unit/state_class defaults — PARTIAL; true but not
  printed on the DHT page (sensor-base level). Only humidity accuracy_decimals=0 is
  on the DHT page.

**Nothing was outright DENIED.** All load-bearing claims hold.

### 2026-06-14 — Round 1 vote

**VOTE: YAE.**

Reviewed `docs/plan/implementation-plan.md` against all 50 Round-1 verdicts.
Every factual claim that made it into the plan matches my verdicts; nothing is
overstated or contradicts my findings.

Verified line-by-line:
- Pin map (§3 lines 66-67) — D0=16/D1=5/D2=4/D3=0/D4=2(LED)/D5=14/D6=12/D7=13/
  D8=15 matches CONFIRMED #1-#10; strapping pins #11-#14; LED active-LOW #15;
  flash GPIO6-11 #16; UART GPIO1/3 #10. DATA=D5/GPIO14 = #6/#22.
- `pullup: false` for breakout (D1, lines 16/38/61) = CONFIRMED #26.
- DHT22 at 3.3V (lines 49-50) = CONFIRMED #23. Plan asserts NO specific upper
  voltage bound, correctly sidestepping the #24 PARTIAL (3.3-6V vs 3.3-5.5V).
- `model: DHT22` (line 159) = CONFIRMED #28. "do not rely on auto" is framed as
  "set explicitly" (sound), not "auto is broken" (#31 PARTIAL) — acceptable.
- api+mqtt coexist (lines 25-26) = CONFIRMED #33.
- 15-min reboot + `reboot_timeout: 0s` fix (lines 128-130) = CONFIRMED #34/#35
  verbatim. Plan uses the correct 15-min figure, NOT the community thread's
  wrong "5 min" (my discrepancy #1).
- `discovery: false` → no duplicate HA entities (lines 153/265-266) = #37
  (CONFIRMED mechanism / PARTIAL specific-fix). Plan presents it as the team's
  design choice, not a doc quote — correct framing per my note #3.
- MQTT defaults: 1883 (#39), retain true (#40), retained `<prefix>/status`
  online/offline (#44), topic structure (#45). All CONFIRMED.
- web_server off "RAM/stability on ESP8266" (line 285) = CONFIRMED #46 verbatim.
- state_class measurement → HA statistics (lines 259-260) = #32 (true; documented
  at sensor-base level). Behavior claim correct.
- esphome/issues#3695 (line 296) explicitly labeled "Fact-Checker UNVERIFIED" and
  non-blocking = honest match to #38.
- CH340/CP2104 (lines 37/293) hedged "CH340 typical; CP2104 on some clones" =
  matches PARTIAL #21.

NITs (non-blocking):
- Line 71 "rely on the external resistor and leave `pullup: false`" for a bare
  4-pin sensor is electrically fine but slightly muddled; not the current build.
- §9.1 "up to ~5 min" mDNS discovery time is a reasonable estimate, not a spec.
- Line 159 comment "do not rely on auto" leans on advisory #31; harmless.

No factual error found. All load-bearing claims verified against authoritative
sources. YAE.
