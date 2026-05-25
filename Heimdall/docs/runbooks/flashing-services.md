# Heimdall — Hyperion flashing services runbook

Operator-facing runbook for the three services that moved from Akasha to Heimdall during the `dev-hyperion-flashing-to-heimdall` pipeline (FINAL.md in `docs/pipeline-runs/20260521T144651Z-dev-hyperion-flashing-to-heimdall/`). The stack is **temporary** — when Akasha's replacement comes online or 12 months elapse (whichever first), a follow-up pipeline decides re-migrate vs. adopt-Heimdall-as-permanent.

## What's running

Source: `Heimdall/hyperion/` (compose file + image source dirs). State root on Heimdall: `/opt/Homelab/Heimdall/hyperion/`.

| Service | Port | Purpose |
|---|---|---|
| `nginx` | `50011` | Serves Node IMG + Bootstrap IMG to Pis during flashing |
| `ci-deploy` | (no port; polls GH) | Mirrors GitHub Releases → `/opt/Homelab/Heimdall/hyperion/images/` every 5 min |
| `journal-remote` | `19532` | Receives `systemd-journal-upload` pushes from each Pi |
| `journal-gatewayd` | `19531` | HTML5 UI to browse the collected journal (`/browse`) |

journal-remote and journal-gatewayd share **one container** (same image) coordinated by a tiny Python supervisor (`Heimdall/hyperion/journal-remote/entrypoint.py`). See below for the v2 escape hatch if this coupling becomes problematic.

## URLs the operator uses

- **Live monitor a single Pi during flashing** — workstation: `Hyperion/watch-flash.sh <node>`
- **Historical journal browse** — any browser on the LAN: `http://192.168.10.4:19531/browse`
- **Image manifest** — sanity-check from a Pi shell or workstation: `curl http://192.168.10.4:50011/node/manifest.json | jq .`
- **Bootstrap medium availability** — `curl -I http://192.168.10.4:50011/bootstrap/rpi-bootstrap.img`

## Backup decision

**Journal data is treated as DISPOSABLE.** Retention is enforced by a workstation-triggered prune that the operator runs ad-hoc or via cron on Heimdall.

Rationale: the journal-remote data is high-value DURING and IMMEDIATELY AFTER a flashing incident (operator uses `watch-flash.sh` for live data + gatewayd `/browse` for cross-attempt history). After ~30 days, the entries cease to be load-bearing for any operational decision; long-term node behavior is captured in commits, runbooks, and pipeline runs.

Suggested prune (run from Heimdall, manual or weekly cron):

```bash
# Keep 30 days; cap total to 2 GiB. The bind-mount root is owned by the
# in-container systemd-journal-remote user (UID 999); use sudo on the host.
sudo journalctl -D /opt/Homelab/Heimdall/hyperion/journal --vacuum-time=30d
sudo journalctl -D /opt/Homelab/Heimdall/hyperion/journal --vacuum-size=2G
```

When Akasha was hosting this, journal data lived on `/mnt/Media-Storage/...` which had its own backup story via the TrueNAS snapshot cron. Heimdall does not have that. Re-evaluate this decision if a Pi failure cluster requires looking back > 30 days; in that case, add `/opt/Homelab/Heimdall/hyperion/journal/` to `Heimdall/scripts/backup.sh`'s rsync set.

## Pre-deploy smoke test

Before the first `docker compose up -d`, run the following on a workstation (or in a throwaway Docker host):

```bash
cd Heimdall/hyperion/journal-remote
docker build -t journal-remote-test .
# Smoke 1: both daemons start under the supervisor and stay up for 10s.
CID=$(docker run -d --rm journal-remote-test)
sleep 10
docker ps --filter "id=$CID" --format '{{.Status}}'    # should be "Up 10 seconds"
# Smoke 2: gatewayd serves /browse (404 on root, 200 on /browse)
docker exec "$CID" wget -qO- http://127.0.0.1:19531/browse | head -1
# Smoke 3: journal-remote accepts a connect on 19532 (returns 404 to GET /;
# 404 means listener is alive — that's what we want).
docker exec "$CID" wget -qO- http://127.0.0.1:19532/ 2>&1 | grep -E '404|400'
# Smoke 4: SIGTERM forwarding — supervisor reaps both children cleanly.
docker stop "$CID" --time=10
docker logs "$CID" 2>&1 | grep -E "SIGTERM received|exited with status"
docker rm -f "$CID" 2>/dev/null
docker rmi journal-remote-test
```

Smokes 1-4 close FC UNVERIFIED items #1, #2 from the pipeline FINAL.md and verify Linux Expert's HIGH-priority supervisor concerns (T2.1 SIGCHLD race, T2.2 SIGTERM forwarding). If ANY of them fail, do not deploy — fix the entrypoint and re-test.

## V2 escape hatch — split into two containers

If `journal-remote` or `journal-gatewayd` crashes more than **once per week** in production, abandon the coupled-container design and split into two containers:

```yaml
  # Compose snippet replacing the current journal-remote service
  journal-remote-receiver:
    image: ghcr.io/stevengann/homelab-journal-remote:<sha>
    entrypoint: ["/lib/systemd/systemd-journal-remote",
                 "--listen-http=19532",
                 "--output=/var/log/journal/remote/",
                 "--split-mode=host"]
    # ... same ports/volumes for 19532 only

  journal-remote-gatewayd:
    image: ghcr.io/stevengann/homelab-journal-remote:<sha>
    entrypoint: ["/lib/systemd/systemd-journal-gatewayd",
                 "--directory=/var/log/journal/remote/"]
    # ... ports/volumes for 19531 only; read-only on /var/log/journal/remote
```

Both pull the same image (`homelab-journal-remote:<sha>`); the entrypoint override is the only difference. No new image, no new CI workflow.

## Common operations

### Bring up the stack
```bash
# From the workstation (with the age key available):
Heimdall/scripts/deploy.sh
# Then verify on Heimdall:
ssh owner@192.168.10.4 'cd /opt/Homelab/Heimdall/hyperion && docker compose ps'
```

### Pin a SHA tag (rollback to a known-good image)
After CI builds a new image, GHCR has both `:latest` and `:sha-<commit>`. To pin Compose to a specific SHA:
```yaml
# In Heimdall/hyperion/docker-compose.yml — change the line
image: ghcr.io/stevengann/homelab-journal-remote:latest
# ↓
image: ghcr.io/stevengann/homelab-journal-remote:sha-abc123def
```
Commit, push, run `Heimdall/scripts/deploy.sh`.

### Tail journal-remote logs on Heimdall
```bash
ssh owner@192.168.10.4
cd /opt/Homelab/Heimdall/hyperion
docker compose logs -f journal-remote
```

### Verify a Pi is uploading to Heimdall (not Akasha)
On the Pi (post-flash, NVMe-booted):
```bash
cat /etc/systemd/journal-upload.conf.d/akasha.conf      # URL should be 192.168.10.4:19532
systemctl status systemd-journal-upload.service           # active, no errors
journalctl -u systemd-journal-upload.service -n 50        # successful Push entries
```
On Heimdall, the per-host journal file appears under `/opt/Homelab/Heimdall/hyperion/journal/`:
```bash
ssh owner@192.168.10.4 sudo ls -la /opt/Homelab/Heimdall/hyperion/journal/
```

### Reset journal state (destructive — only for clean reinstall)
```bash
ssh owner@192.168.10.4
cd /opt/Homelab/Heimdall/hyperion
docker compose stop journal-remote
sudo rm -rf /opt/Homelab/Heimdall/hyperion/journal/*
docker compose start journal-remote
```

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| Pi can't reach `:50011/node/manifest.json` | nginx container status: `docker compose ps nginx`; route from Pi: `ip route show; curl -v --max-time 5 http://192.168.10.4:50011/node/manifest.json` |
| `:8080/` on a Pi shows `image_server_base = http://192.168.10.247:...` | That Pi has an OLD Bootstrap medium. Re-flash from the workstation: `cd Hyperion && ./reimage.sh <node>` |
| `journal-upload` service on a Pi fails to push | Confirm Heimdall is reachable from the Pi VLAN; `curl -I http://192.168.10.4:19532/` returns 405 (Method Not Allowed = receiver alive). 404 also means alive |
| gatewayd `/browse` returns empty list | journal-remote not receiving. Check the supervisor logs (see "Tail journal-remote logs" above); verify the bind-mount path `/opt/Homelab/Heimdall/hyperion/journal/` exists |
| Container restarts every few seconds | The supervisor exits non-zero when EITHER daemon exits. Read `docker compose logs journal-remote` for the daemon-name + status line printed before the exit |

## Related docs

- `docs/pipeline-runs/20260521T144651Z-dev-hyperion-flashing-to-heimdall/FINAL.md` — full migration design + the four-tier implementation checklist this runbook implements.
- `Hyperion/docs/runbooks/debug-flashing.md` — H1–H6 SSD-not-flashing taxonomy. The realtime tooling here is what the H1–H6 debug protocol uses.
- `Hyperion/watch-flash.sh` — workstation-side companion: live view of a single Pi during flashing.
- `Heimdall/hyperion/journal-remote/Dockerfile` — Dockerfile comments document the design constraints and the v2 escape hatch.
