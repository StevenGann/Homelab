# Bifrost

The cluster's single routing point for model backends — cloud (DeepSeek,
Anthropic, ElevenLabs) and in-cluster (the `embeddings` Deployment, see
`embeddings.yaml` and `Hyperion/docs/runbooks/embeddings-service.md`). Every agent
that speaks to a model goes through it, which is the point: when a backend moves,
changes shape, or is swapped out, one `BACKENDS`/`ROUTES` edit re-points every
consumer.

## Where it runs, and why not on Heimdall

It runs as a single pod on a Hyperion worker, selected by
`topology.kubernetes.io/zone: hyperion`.

Putting it on Heimdall is the natural wish — Heimdall already serves DNS
(Technitium) and the reverse proxy, and Bifrost is the same class of dependency
for AI compute that Technitium is for names. It was measured on 2026-11-03 and it
does not work today:

- The pod schedules onto `heimdall-control-plane` and becomes Ready, but it is
  **unreachable from every worker**. `worker → control-plane-pod` times out for
  the pod IP, the ClusterIP, and the MetalLB VIP alike.
- The cause is not the taint. The k3s control plane runs as a **Docker container
  on Docker's default bridge** (`172.19.0.2`), so its flannel VTEP cannot send
  return traffic to the Pis. This is ADR-0002, and it names this exact failure:
  "any pod scheduled on the control-plane node is unreachable from the workers".
- The `node.homelab/control-plane-only=true:NoExecute` taint exists to enforce
  that finding. A per-pod toleration defeats the guard without fixing the
  network — the pod comes up healthy and serves nobody.

So do not re-add a toleration for this node expecting a working workload. If
Bifrost should live on Heimdall, it has to be a **host container** next to
Technitium and Caddy (the way Heimdall already runs its edge services), not a
Kubernetes pod; and its `embed` backend would then need an address that is
routable from the host — a MetalLB VIP for the `embeddings` service rather than
its ClusterIP.

The other path is the one ADR-0002 already plans: relocate the control plane off
the bridge-networked container (`network_mode: host`, its own host, or the
Heimdall host OS). Until that happens, Heimdall is not a workload host.

## Anthropic routes and prompt caching

The `claude*` routes are secondary: DeepSeek is the default every agent uses,
and a Claude route runs only when something names one. What makes naming one
affordable is the prompt cache.

Bifrost marks three `cache_control` prefixes on each translated request — the
last tool definition, the last system block, and the newest message — so
Anthropic keeps the agent's stable prefix for five minutes. Later hits bill at
0.1x the input rate; writes cost 1.25x. The gateway prices both and records
them per ledger line as `cache_read` / `cache_write`.

Measured 2026-11-03 on `claude-haiku-5-5` with a 5,179-token prompt:

| call | cache write | cache read | cost |
|---|---|---|---|
| cold | 5,175 | 0 | $0.000649 |
| repeat | 0 | 5,175 | $0.000054 |

The switch is the ConfigMap's `ANTHROPIC_PROMPT_CACHE` (default on; `0`
disables the markers without a rebuild).

`/v1/models` advertises `context_length: 200000` for every `claude*` route.
That is load-bearing: Hermes probes for it, and without an answer it falls back
to its own table, which matched `claude-opus-5` and claimed 1,000,000 tokens.
It then never compacted before Anthropic's real 200k limit, and every long
session ended in a context-length 400 that read like a model fault.

## Anthropic key pool

The `anthropic` backend carries **two** credentials via `KEYPOOL` in
`secret.sops.yaml`, with pool ids `primary` and `secondary`. `ANTHROPIC_API_KEY`
is still present and holds the same value as `primary`; the pool is what the
gateway actually rotates across, and the single-key variable is only a fallback
if `KEYPOOL` is ever removed.

The point is rate limits, not load balancing. On a rate-limit or auth rejection
the serving key cools down for 30 seconds and the retry picks the other one
before backend failover is ever considered. A 429 from one credential therefore
looks like a brief retry to the caller instead of a 502.

Ledger lines and metrics attribute the request to the pool id (`upstream_key:
primary` / `secondary`), never to key material. Both keys are per-request
round-robin, so ordinary traffic spreads across them.

To add or replace a key: `sops set` the `KEYPOOL` entry, push, then bounce the
Deployment — `envFrom` is read at container start, so a Flux reconcile alone
leaves the running process on the old pool. Verify on the ledger, not on a 200:
the row's `upstream_key` names the credential that answered.

## Storage

`bifrost-data` is a 1 Gi `local-path` claim, bound **by name** to the PV that
holds the ledger. That binding is deliberate: the volume holds the record of what
every request cost, and a re-provisioned empty volume would silently restart the
month's totals — the gateway would keep serving and only the accounting would be
gone.

- `spend.jsonl` — one JSON line per request: app, route, backend, tokens, cost,
  and for cached traffic the `cache_read` / `cache_write` split.
  The monthly budget, the spend dashboard, and any future rotation policy read
  from this file.
- `keys.json` — upstream key pool state.
- `spend.archived-20261030.jsonl` — rotated history; keep it with the live file.

There is no `tar` in the bifrost image (`FROM scratch`), so the ledger cannot be
copied out of the running pod. Mount the PV's host path in a throwaway pod and
`kubectl cp` from there. Stop the deployment first: a copy taken mid-flight
misses the last writes, and the point of the file is that its totals are exact.
