# Bifrost on Heimdall

Bifrost is the cluster's single routing point for model backends — cloud
(DeepSeek, Anthropic, ElevenLabs) and in-cluster (the `embeddings` Deployment).
Every agent that speaks to a model goes through it, which is the point: when a
backend moves, changes shape, or is swapped out, one `BACKENDS`/`ROUTES` edit
re-points everything.

## Why it lives on Heimdall

Heimdall already runs the services that everything else depends on: DNS
(Technitium), the reverse proxy, and the edge routing for the LAN. Bifrost is the
same class of component for AI compute that Technitium is for names — a single
place to update when the thing behind it moves. Putting it on a worker instead
would mean a node drain for an unrelated rebuild takes down model access for
every agent, and would tie the gateway's address to whichever worker happened to
host the pod.

**This is an exception to the control-plane taint.** Heimdall carries
`node.homelab/control-plane-only=true:NoExecute`, and the deployment tolerates it
explicitly, per-pod. Nothing else should copy that toleration; the taint is what
keeps a 28-core box from silently becoming the busiest worker in the cluster. If
another workload needs to run on Heimdall, add it here on purpose with a reason,
not by widening someone else's manifest.

## Storage

`bifrost-data` is a **static** PV (`pv.yaml`), not a local-path claim. The
local-path provisioner is a single Deployment on `hyperion-eta`; it materialises
directories through a helper pod that cannot schedule onto the tainted node, so a
dynamically provisioned PVC would sit `Pending` forever. The PV is a hostPath at
`/var/lib/rancher/k3s/storage/bifrost-static-data` with a node affinity for
Heimdall and `reclaimPolicy: Retain`.

The volume holds two things, both of which are the record of what happened:

- `spend.jsonl` — one JSON line per request: app, route, backend, tokens, cost.
  The monthly budget, the spend dashboard, and any future rotation policy all
  read from this file.
- `keys.json` — upstream key pool state.
- `spend.archived-20261030.jsonl` — rotated history; keep it with the live file.

Ownership is fixed by the `prepare-data` init container: hostPath volumes are
created by kubelet as root and `fsGroup` does not apply to them, so bifrost
(nobody/65534) would fail to write the ledger otherwise. The failure is silent —
the gateway serves fine and only the accounting disappears — which is why the
init container runs on every start rather than being a one-time host step.

## Migrating the volume

There is no `tar` in the bifrost image (`FROM scratch`), so the ledger cannot be
copied out of the running pod. Use a throwaway pod that mounts the PV path and
`kubectl cp` from there. Stop the deployment first: a copy taken mid-flight
misses the last writes, and the whole point of the file is that its totals are
exact.
