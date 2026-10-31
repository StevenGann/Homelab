# Guppy break-glass — restoring the agent when it cannot restore itself

**Scope:** Guppy (the operator's Hermes agent), namespace `hermes`, deployment
`hermes`, node `hyperion-kappa`.

**Use this when:** Guppy is not answering on Discord/API, the `hermes` pod is
missing or not Ready, or it is answering in a degraded state.

---

## Why this exists

On 2026-10-30 a migration script scaled the `hermes` deployment to zero and then
failed, because the script's own `kubectl` was not on the `PATH` of the shell it
ran in. The pod stayed down for hours. The operator pinged Jeeves immediately,
but Jeeves had no credentials for the `hermes` namespace and could not act. The
recovery waited until a human was home and could start a different agent.

Every piece of this runbook exists because of a specific thing that failed that
day. Do not remove a step because it looks redundant — the redundancy is the
lesson.

---

## 0. Confirm it is actually down (60 seconds)

```bash
export KUBECONFIG=/opt/data/k3s.yaml   # on Guppy itself; elsewhere use ~/.kube/config
kubectl -n hermes get pods -l app=hermes
kubectl -n flux-system get kustomization hermes -o wide
```

Three checks, all must fail before you act:

| Check | Healthy looks like |
|---|---|
| Pod exists and is `2/2 Running` | `hermes-<hash>-<id>   2/2   Running   <restarts>` |
| Health endpoint responds | `curl -s -o /dev/null -w '%{http_code}' http://<pod-ip>:8646/health` → `200` |
| Heartbeat is fresh | `kubectl -n hermes exec <pod> -c hermes -- stat -c %Y /opt/data/cron/ticker_heartbeat` |

A single red check with the others green is usually a transient — wait five
minutes before escalating. Two or more red for more than 15 minutes is real.

**Do not** delete the pod as a first move. A delete restarts it and destroys the
evidence you need if it is crashlooping.

---

## 1. Diagnose read-only

```bash
kubectl -n hermes describe deploy hermes | head -40      # replica count, conditions
kubectl -n hermes logs -l app=hermes -c hermes --tail=100 --previous
kubectl -n hermes get events --sort-by=.lastTimestamp | tail -20
kubectl -n flux-system get kustomization hermes -o jsonpath='{.status.conditions}'
```

Classify:

- **`spec.replicas` is 0, pod absent** → someone/something scaled it down. Step 2.
- **Pod exists but `CrashLoopBackOff`/not Ready** → read `--previous` logs. Step 3.
- **Pod Running, `/health` fails** → usually a config or state problem. Step 4.
- **Deployment missing entirely** → Flux owns it. `flux reconcile kustomization hermes --with-source`, then re-check; if Flux is suspended, unsuspend it:
  `kubectl -n flux-system patch kustomization hermes --type merge -p '{"spec":{"suspend":false}}'`

---

## 2. First-line fix — scale it back up

This alone fixes the commonest failure (something scaled Guppy to zero).

```bash
kubectl -n hermes scale deploy hermes --replicas=1
kubectl -n hermes rollout status deploy/hermes --timeout=180s
```

Then confirm it is actually working, not merely Running:

```bash
kubectl -n hermes exec deploy/hermes -c hermes -- tail -20 /opt/data/logs/gateway.log
# look for: "✓ discord connected"
```

**If Flux is mid-reconcile it may fight a manual scale.** Suspend first, scale,
verify, then unsuspend:

```bash
kubectl -n flux-system patch kustomization hermes --type merge -p '{"spec":{"suspend":true}}'
kubectl -n hermes scale deploy hermes --replicas=1
kubectl -n flux-system patch kustomization hermes --type merge -p '{"spec":{"suspend":false}}'
```

> This is exactly what went wrong on 2026-10-30: a manual scale was reverted by
> Flux mid-recovery.

---

## 3. Crashlooping

```bash
kubectl -n hermes logs -l app=hermes -c hermes --tail=200 --previous
kubectl -n hermes describe pod -l app=hermes | tail -30
```

Common causes and what they mean:

| Symptom in logs | Meaning | Fix |
|---|---|---|
| `address already in use` | Orphaned process from the old container | Delete the pod; it is a single-replica deployment |
| `no space left on device` | The data partition filled | See §5 — the home is on `/mnt/node-storage` (202 GB), so this should be structural, not routine |
| `unable to open database file` / `database disk image is malformed` | `state.db` damaged | §4 restore |
| config parse error | A bad `config.yaml` edit | `kubectl -n hermes exec … -- cp /opt/data/config.yaml.bak-<date> /opt/data/config.yaml`, or restore from backup §4 |

Roll back to the previous image only if the current image is the new variable:

```bash
kubectl -n hermes set image deploy/hermes hermes=ghcr.io/stevengann/hermes:<previous-tag>
```

…but prefer fixing forward: the deployment is GitOps-owned, so a manual image
change will be reverted by Flux on the next reconcile. Fix the repo instead.

---

## 4. Restore from backup

> **Path note:** the share is `Infra-Storage`, not `Backups`. There is no
> `/mnt/Media-Storage/Backups` export on Akasha — mounting it fails with exit 32,
> and `showmount -e <akasha-ip>` is the authority on what is actually exported.


Backups are taken nightly at 03:17 UTC by `hermes-backup` (CronJob) into
`/mnt/Media-Storage/Infra-Storage/hermes/<UTC timestamp>/` on Akasha, each containing:

- `state.db.gz` — a consistent SQLite `.backup` snapshot
- `home.tgz` — `config.yaml`, `SOUL.md`, `memories/`, `skills/`, `cron/`, `.env`
- `SHA256SUMS`

**Procedure:**

1. Scale Guppy to zero so nothing writes during the restore.
   ```bash
   kubectl -n hermes scale deploy hermes --replicas=0
   ```
2. On kappa, mount Akasha's `Backups` share and pick a snapshot:
   ```bash
   SNAP=<timestamp>            # e.g. 20261031T031700Z
   mkdir -p /mnt/akasha-backups
   mount -t nfs -o nfsvers=4.1 <akasha-ip>:/mnt/Media-Storage/Infra-Storage /mnt/akasha-backups
   cd /mnt/akasha-backups/hermes/$SNAP && sha256sum -c SHA256SUMS   # must print OK for both files
   ```
3. **Move, never delete, the current data.** It may be the only copy of the last
   few hours.
   ```bash
   mv /mnt/node-storage/hermes-data /mnt/node-storage/hermes-data.broken-$(date -u +%Y%m%dT%H%M%SZ)
   mkdir -p /mnt/node-storage/hermes-data
   ```
4. Restore:
   ```bash
   tar -xzf /mnt/akasha-backups/hermes/$SNAP/home.tgz -C /mnt/node-storage/hermes-data
   gunzip -c /mnt/akasha-backups/hermes/$SNAP/state.db.gz > /mnt/node-storage/hermes-data/state.db
   chown -R 10000:10000 /mnt/node-storage/hermes-data
   ```
5. Scale up and verify:
   ```bash
   kubectl -n hermes scale deploy hermes --replicas=1
   kubectl -n hermes rollout status deploy/hermes --timeout=180s
   kubectl -n hermes logs -l app=hermes -c hermes --tail=40 | grep -i "connected"
   ```

`hermes-data.broken-*` is kept deliberately. Delete it only after Guppy has been
healthy for a day.

---

## 5. Disk pressure on kappa

Guppy's home is a `hostPath` on kappa's **node-storage** partition
(`/mnt/node-storage/hermes-data`, ~202 GB). The 32 GB root (`p2`) holds the OS,
containerd images and other PVCs.

```bash
kubectl get --raw "/api/v1/nodes/hyperion-kappa/proxy/stats/summary" | jq '.node.fs'
```

If images are the problem: `k3s crictl rmi --prune` on kappa.
If `/nix` is the problem: `nix-collect-garbage -d`.
If Guppy's home is the problem, find the consumer with `du -xh -d1` and prune
backups, not the live database.

---

## 6. What Jeeves can do, without kubectl

Jeeves has a ServiceAccount with `get/list/watch` on pods and deployments, `get`
on logs, and `patch` on `deployments/scale` in the `hermes` namespace — and
nothing else. It has `curl` but no `kubectl`, so it calls the API directly:

```sh
API=https://kubernetes.default.svc
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat $SA/token)

# is Guppy's pod alive?
curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$API/api/v1/namespaces/hermes/pods?labelSelector=app%3Dhermes"

# what does the deployment think it should be doing?
curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$API/apis/apps/v1/namespaces/hermes/deployments/hermes"

# last 100 log lines
curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$API/api/v1/namespaces/hermes/pods/<pod>/log?container=hermes&tailLines=100"

# bring Guppy back
curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/merge-patch+json" -X PATCH \
  "$API/apis/apps/v1/namespaces/hermes/deployments/hermes/scale" \
  -d '{"spec":{"replicas":1}}'
```

Jeeves' standing instruction (see its SOUL/skills): if Guppy is down for three
consecutive 5-minute checks, DM the operator with the diagnosis, then scale the
deployment to 1. Repeat at most three times, then stop and escalate — a rescue
loop that scales forever hides the underlying fault.

---

## 7. Rules that keep this from recurring

1. **Never run a destructive operation on Guppy's own workload from inside
   Guppy.** Use a separate privileged pod that outlives the restart.
2. **Any script that can take Guppy down must have a `trap`/`finally` that puts
   it back, and must verify its own dependencies first** — the 2026-10-30
   failure was a missing `PATH`, which would have been caught by one `command -v`.
3. **Never structure a change so the only path back runs through the thing being
   changed.**
4. **If you scale a GitOps-owned deployment by hand, suspend the Kustomization
   first** and unsuspend afterwards.
5. **Nothing that holds operational state loses its `.git`** without a verified
   remote copy first.
6. **Backups are only real once restored.** Run the drill monthly: restore the
   newest snapshot into a scratch copy and boot from it before trusting it.

---

## 8. Rehearsal (do this quarterly, not during an incident)

```bash
# 1. Take a backup by hand
kubectl -n hermes create job --from=cronjob/hermes-backup backup-drill-$(date +%s)

# 2. Confirm the artifact landed and verifies
#    (mount Akasha's Infra-Storage share, cd into the newest dir, sha256sum -c SHA256SUMS)

# 3. Restore it somewhere harmless and boot it
#    Restore into /mnt/node-storage/drill/ and start a throwaway pod mounting it.
#    Success = it reaches "✓ discord connected" with a copy of state.db.

# 4. Delete the drill data.
```

A backup that has never been restored is a hope, not a backup.
