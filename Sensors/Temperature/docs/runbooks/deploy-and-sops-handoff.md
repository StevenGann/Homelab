# Deploy & SOPS Handoff Runbook

**Audience:** the agent/operator on the system that **holds the SOPS age key**.
**Status of the project:** plan APPROVED (5 YAE / 0 NAY, 2026-06-14); all config files
scaffolded. **SOPS migration (Part B) is DONE (2026-06-14):** real secrets are encrypted
to the committed `secrets.sops.yaml` (age recipient = operator key), the plaintext
`secrets.yaml` is gitignored and regenerated on demand by `scripts/decrypt-secrets.sh`
(invoked automatically by `scripts/flash.sh`). Part B below is retained as reference.

This runbook is self-contained. Source of truth for design rationale:
[`../plan/implementation-plan.md`](../plan/implementation-plan.md); team/process:
[`../team/TEAM.md`](../team/TEAM.md).

---

## Part A — Deploy a node (no SOPS required)

### A0. Hardware
DHT22 **breakout module** (onboard pull-up → no external resistor) to the D1 mini:

```
DHT22 module        D1 mini
  VCC  ───────────── 3V3        (board is 3.3V logic, NOT 5V tolerant)
  DATA ───────────── D5  (GPIO14)
  GND  ───────────── G
```
Data-capable USB cable, **≥500 mA** supply (weak power → WiFi-TX brownout reboots).
Keep the DATA run < ~1 m.

### A1. Toolchain (once)
```bash
sudo apt install -y pipx && pipx ensurepath
pipx install esphome
sudo usermod -aG dialout "$USER"      # then log out / back in
# if /dev/ttyUSB0 never appears: sudo apt remove brltty
```

### A2. Secrets (interim, plaintext)
```bash
cd Sensors/Temperature
cp secrets.yaml.example secrets.yaml   # if not already present
$EDITOR secrets.yaml                   # fill REAL values; file is gitignored
# api_encryption_key:  openssl rand -base64 32
```
Required keys: `wifi_ssid`, `wifi_password`, `fallback_ap_password`,
`api_encryption_key`, `ota_password`, `mqtt_broker`, `mqtt_username`, `mqtt_password`.

### A3. Validate + first flash (USB)
```bash
esphome config nodes/temp-living-room.yaml         # must pass clean
./scripts/flash.sh nodes/temp-living-room.yaml     # choose /dev/ttyUSB0
```
D1 mini auto-resets (no button dance). In the serial log confirm: WiFi → API up →
MQTT connected → first **non-NaN** reading.

### A4. Integrate
- **Home Assistant:** auto-discovered (Settings → Devices & Services → ESPHome) or
  add by `temp-living-room.local`; paste `api_encryption_key`. Entities:
  `Living Room Temperature` / `Humidity`, with long-term statistics.
- **MQTT:** `mosquitto_sub -t 'sensors/#' -v` → `sensors/<location>/temperature`,
  `sensors/<location>/humidity`, and retained `sensors/<location>/status=online`.
  **Non-HA consumers MUST gate on `status == online`** (avoids trusting a stale
  retained value when a node dies).

### A5. Day-2
- **Updates are OTA:** re-run `./scripts/flash.sh nodes/<node>.yaml`, pick the network
  target. One change at a time (no boot menu on ESP8266; bad OTA = physical re-flash,
  recoverable via the fallback AP + captive portal).
- **New node:** copy `nodes/temp-living-room.yaml`, change `node_name` /
  `friendly_name`, flash.

---

## Part B — Migrate secrets to SOPS+age (the handoff task)

Do this on the system that has the operator age key (repo convention:
`~/.config/sops/age/keys.txt`, per the monorepo `CLAUDE.md`). Goal: commit an
**encrypted** `secrets.sops.yaml`, keep the plaintext `secrets.yaml` gitignored, and
make `esphome run` decrypt on demand. The layout was designed so this is drop-in.

### B1. Create `.sops.yaml` (encryption rules for this dir)
Get the age **public** key (`age1…`) — e.g. `grep -o 'age1[0-9a-z]*'
~/.config/sops/age/keys.txt` or `age-keygen -y ~/.config/sops/age/keys.txt`. Then:

```yaml
# Sensors/Temperature/.sops.yaml
creation_rules:
  - path_regex: secrets\.sops\.yaml$
    age: "age1XXXXXXXX...operator-public-key..."
```
(Add more `age:` recipients comma-separated if other operators/agents must decrypt.)

### B2. Encrypt the filled-in plaintext into the committed copy
```bash
cd Sensors/Temperature
# secrets.yaml must already contain the REAL values (Part A2).
# NOTE: sops matches creation_rules against the INPUT path, and the rule targets
# secrets.sops.yaml — so copy to that name first, then encrypt IN PLACE. Encrypting
# secrets.yaml directly fails with "no matching creation rules found".
cp secrets.yaml secrets.sops.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --encrypt --in-place secrets.sops.yaml          # COMMIT this file
```

### B3. Add the decrypt helper
```bash
cat > scripts/decrypt-secrets.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
  sops --decrypt secrets.sops.yaml > secrets.yaml
echo "secrets.yaml written (gitignored)."
EOF
chmod +x scripts/decrypt-secrets.sh
```

### B4. Wire decrypt into the flash wrapper
In `scripts/flash.sh`, **uncomment/enable** the decrypt step so it runs before
`esphome run` (the placeholder block and a guard are already in the file):
```bash
./scripts/decrypt-secrets.sh        # regenerates plaintext secrets.yaml from SOPS
esphome run "$NODE"
```

### B5. Edit secrets thereafter
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets.sops.yaml   # edit encrypted
```

### B6. Verify nothing leaks
```bash
git check-ignore secrets.yaml              # -> matched (ignored). GOOD.
git status                                  # secrets.sops.yaml shows as a NEW tracked file;
                                            # plaintext secrets.yaml must NOT appear.
git check-ignore common/secrets.yaml || echo "relay tracked - GOOD"
```
`common/secrets.yaml` is the value-less relay (`<<: !include ../secrets.yaml`) and
**stays committed** — `.gitignore` anchors `/secrets.yaml` so only the root plaintext
is ignored.

### B7. Optional hardening (Devil's Advocate)
Add a pre-commit hook that hard-fails if a plaintext `secrets.yaml` with real values
is ever staged (defense against `git add -f`).

---

## Files reference

| Path | Committed? | Purpose |
|------|-----------|---------|
| `secrets.yaml` | **No (gitignored)** | Plaintext ESPHome reads at compile (placeholders now → real values) |
| `secrets.yaml.example` | Yes | Template / key list |
| `secrets.sops.yaml` | Yes (Part B) | Encrypted copy of real secrets |
| `common/secrets.yaml` | Yes | Value-less relay so `!secret` resolves from `common/` |
| `.sops.yaml` | Yes (Part B) | age recipients |
| `common/dht22-node.yaml` | Yes | All shared firmware logic |
| `nodes/<node>.yaml` | Yes | Per-node substitutions + package include |
| `scripts/flash.sh` / `decrypt-secrets.sh` | Yes | Flash / decrypt helpers |
