# ArchiSteamFarm (ASF)

Migrated from the workstation's local `~/Downloads/ASF-linux-x64` install into
the cluster on 2026-07-04. Runs the official multi-arch image on the Pi workers.

| | |
|---|---|
| Image | `justarchi/archisteamfarm:6.3.7.0` (arm64) |
| Web UI / IPC | `http://192.168.10.85` (also `:1242`, the native ASF port) — LoadBalancer |
| Auth | `IPCPassword` (in the SOPS secret) — required for the UI/API |
| Node | `topology.kubernetes.io/zone=hyperion` (Pi workers) |
| Storage | `asf-config` PVC (`local-path`, node-local) mounted at `/app/config` |

## How config + state are split

ASF wants a single writable `/app/config` holding both its JSON config and its
binary session databases. We keep **git as the source of truth for config** and
let **ASF own its live session**, via the `seed-config` initContainer:

- **`ASF.json`, `IPC.config`, `Main Bot.json`** — copied from the `asf-seed`
  Secret into the PVC **on every start** (overwrite). Change these in git
  (edit the SOPS secret), not through the IPC web UI, or your edits will be
  reverted on the next pod restart.
- **`ASF.db`, `Main Bot.db`, `SteamTokenDumper.cache`** — the authenticated
  Steam session + caches, migrated from the local install. Seeded into the PVC
  **once** (`[ -f ] || cp`) and never overwritten, so restarts keep the login
  and don't re-trigger Steam Guard.

`IPC.config` binds Kestrel to `http://*:1242`; ASF otherwise listens on
localhost only and the LoadBalancer couldn't reach it.

> k8s Secret keys can't contain spaces, so the bot files are stored as
> `Main_Bot.json` / `Main_Bot.db` and renamed to the exact ASF filename
> (`Main Bot.*`) by the initContainer. The bot name stays **`Main Bot`**.

## Secrets

`secret.sops.yaml` is a SOPS-encrypted `Opaque` Secret decrypted by Flux at
apply time (the app's Kustomization sets `decryption: { provider: sops }`).
It carries the Steam login/password, the `IPCPassword`, and the base64 `.db`
session files. Encrypted to the operator + the in-cluster Flux age key, same as
every other `k8s/**/*.sops.yaml`.

Edit it with:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --config Hyperion/.sops.yaml Hyperion/k8s/apps/archisteamfarm/secret.sops.yaml
```

## Changing bot config (add a bot, change farming, etc.)

1. `sops` the secret above; edit the relevant JSON under `stringData`.
2. Commit + push to `origin/main`. Flux re-applies; the initContainer overwrites
   the JSON in the PVC on the next pod roll.

To force an immediate roll: bump the Deployment or delete the pod (needs kubectl).

## Re-seeding / resetting the session

The `.db` files are seed-once. To replace the migrated session with a fresh one,
delete the file inside the PVC (or the whole PVC) so the initContainer re-copies
from the secret — or clear it and let ASF log in fresh (enter the Steam Guard
code via the web UI).

## Notes

- `Headless: true` is kept: the container has no interactive console. With the
  migrated session valid, ASF logs in without prompting. If the session ever
  expires, submit the Steam Guard code through the IPC web UI.
- No `asf.lab` DNS record yet — Technitium records live on Heimdall (not in this
  repo). Use the raw IP, or add an A-record `asf.lab → 192.168.10.85` on
  Heimdall's Technitium if you want the friendly name.
