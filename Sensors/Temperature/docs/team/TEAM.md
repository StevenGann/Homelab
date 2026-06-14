# Temperature Sensor Project — Standing Team

This document defines the standing agent team for the **D1 mini ESP8266 + DHT22 →
ESPHome → Home Assistant + MQTT** project under `Sensors/Temperature/`. It is meant
to be **reused for future work** on this project. When resuming, re-read this file
and each member's notes doc before acting.

## Mission

Build and maintain an ESPHome firmware for a WeMos/LOLIN **D1 mini (ESP8266)** that
reads a **DHT22** temperature/humidity sensor and publishes measurements to a
**Home Assistant** instance (native API) and an **MQTT broker**. Deliverables
include a vetted implementation plan covering wiring, toolchain, and flashing.

## Roster

| # | Member | Role | Focus | Notes doc |
|---|--------|------|-------|-----------|
| 1 | **Senior Dev** | Clean code & tech-debt steward | Maintainability, config hygiene, repeatability, secrets management, avoiding gold-plating | [notes-senior-dev.md](./notes-senior-dev.md) |
| 2 | **Embedded SME** | ESP8266/ESP32 subject-matter expert | Board specifics (D1 mini pinout, flash, power), DHT22 electrical/timing, GPIO constraints, flashing toolchain | [notes-embedded-sme.md](./notes-embedded-sme.md) |
| 3 | **HA/MQTT SME** | Home Assistant & MQTT subject-matter expert | ESPHome native API vs MQTT, discovery, topics/retain/QoS, HA integration, ESPHome dashboard/OTA | [notes-ha-mqtt-sme.md](./notes-ha-mqtt-sme.md) |
| 4 | **Fact Checker** | Verification | Extracts assertions made by other members; confirms/denies via local data or web search; flags unverified claims | [notes-fact-checker.md](./notes-fact-checker.md) |
| 5 | **Devil's Advocate** | Adversarial reviewer | Challenges every member's ideas; surfaces failure modes, hidden assumptions, simpler/cheaper alternatives | [notes-devils-advocate.md](./notes-devils-advocate.md) |

## Notes protocol

- Each member owns exactly one `notes-*.md` file and is the only writer of record
  for it. Members **append**, dated, and never silently delete prior findings —
  superseded findings get a `~~struck~~` line + reason.
- Durable, reusable facts go under a **Settled Knowledge** section; in-flight
  thinking goes under **Working Notes**.
- Cross-reference other members by role name (e.g. "per Embedded SME").

## Iteration & voting protocol

1. **Gather** — each member contributes findings to their notes doc.
2. **Distill** — the orchestrator merges all input into a single plan doc
   (`docs/plan/implementation-plan.md`).
3. **Review & vote** — the plan is handed back to all five members. Each returns a
   **YAE** or **NAY** with reasoning; NAY must cite a concrete, fixable defect.
4. **Iterate** — address NAYs, revise the plan, re-vote.
5. **Gate** — repeat until **no more than one NAY** remains. Record each round in
   the vote log below.

## Vote log

| Round | YAE | NAY | Outcome |
|-------|-----|-----|---------|
| 1 (2026-06-14) | Embedded SME, HA/MQTT SME, Fact Checker, Devil's Advocate | Senior Dev | 4–1 — gate met (≤1 NAY). NAY = real compile defect: `!secret` resolves from `common/`, needed a relay `common/secrets.yaml`. |
| 1 re-vote (2026-06-14) | **all 5** | — | **5–0**. Relay fix applied; Senior Dev flipped to YAE. **Plan APPROVED.** |
