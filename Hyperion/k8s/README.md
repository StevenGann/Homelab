# Hyperion GitOps (FluxCD)

FluxCD reconciles this directory onto the Hyperion k3s cluster. **Read-only
GitOps**: Flux pulls the *public* repo over HTTPS with no credential and never
pushes (no GitHub token involved). Bootstrapped 2026-06-01.

## Layout

```
flux-system/        flux controllers (gotk-components.yaml, flux v2.8.8) +
                    gotk-sync.yaml (GitRepository on the public repo + root Kustomization)
clusters/hyperion/  cluster entrypoint — Flux Kustomization CRs (infrastructure.yaml)
infrastructure/
  metallb/install/  vendored MetalLB native manifest (v0.14.9): controller, speaker, CRDs
  metallb/config/   IPAddressPool 192.168.10.10–99 + L2Advertisement
apps/
  headlamp/         k8s dashboard — LoadBalancer 192.168.10.50
  uptime-kuma/      status monitor — LoadBalancer 192.168.10.51, persistent local-path PVC
```

Reconcile chain: `flux-system` (root) → `clusters/hyperion` → `metallb`
(install, `wait`) → `metallb-config` (pool, `dependsOn: metallb`); and
`clusters/hyperion` → each app Kustomization in `apps.yaml`
(`dependsOn: metallb-config`).

## Running apps

| App | URL | Notes |
|---|---|---|
| Headlamp (dashboard) | http://192.168.10.50 | token login — `kubectl -n headlamp get secret headlamp-admin -o jsonpath='{.data.token}' \| base64 -d` |
| Uptime-Kuma | http://192.168.10.51 | persistent SQLite on a local-path PVC (node-local) |
| Hermes (DeepSeek agent) | http://192.168.10.52 | basic-auth (`admin`); gateway + dashboard, SOPS DeepSeek key — see Hermes section below |

**All apps must set `nodeSelector: { topology.kubernetes.io/zone: hyperion }`**
so they schedule on the Pi workers, not the containerized control-plane node
(whose pods are unreachable — see
`../../Heimdall/k3s-control-plane/README.md` and ADR-0002). Use a
LoadBalancer Service with `annotations: metallb.io/loadBalancerIPs: <ip>` to
pin a stable address from the `.10–.99` pool.

## Bootstrap on a fresh cluster (read-only, no token)

```bash
# from a host with kubectl access to the cluster (or via the control-plane container):
kubectl apply -k Hyperion/k8s/flux-system     # controllers + GitRepository + root Kustomization
# Flux then pulls origin/main and reconciles everything else.
flux get kustomizations -A                     # watch them reach Ready
```

> The manifests must be pushed to `origin/main` first — Flux reads GitHub, not
> your working tree.

## Verify

```bash
flux get kustomizations -A
kubectl -n metallb-system get pods,ipaddresspool,l2advertisement
# smoke test: a LoadBalancer Service should get an IP from 192.168.10.10–99.
```

## Gotchas hit during bootstrap (and their resolutions)

- **MetalLB `speaker` needs in-cluster API access** (`10.43.0.1:443`). The
  containerized k3s control plane initially advertised its docker-internal IP
  (`172.19.0.2`), unroutable from the Pi workers → every worker pod needing the
  API timed out. Fixed in `Heimdall/k3s-control-plane/docker-compose.yml`
  (`--advertise-address=192.168.10.4`). This also healed `kubectl logs/exec` to
  Pi pods.
- The MetalLB **`memberlist` secret** is auto-created by the metallb controller
  on first start — no manual step (early speaker crashes were just that startup
  race plus the advertise-address bug).

## SOPS-encrypted Secrets (Flux decryption) — REQUIRED encryption form

`apps/hermes/` was the first SOPS-decrypted app. Two non-obvious rules, both
of which produce the same opaque error (`failed to decrypt and format ... does
not match sops' data format`) and **both of which still decrypt fine with the
local `sops` CLI** — so verify against these, not against `sops -d`:

1. **Encrypt only `data`/`stringData` values — leave `apiVersion`/`kind`/
   `metadata` PLAINTEXT.** kustomize-controller must identify the resource
   before decrypting. A fully-encrypted Secret (sops default
   `unencrypted_suffix`) encrypts `kind`/`metadata.name` too and breaks Flux.
2. **No comments inside the encrypted body.** sops encrypts comments into
   `#ENC[...]` nodes that the controller's embedded sops can't parse.

Canonical encryption (matches the `k8s/.*\.sops\.ya?ml$` rule in `.sops.yaml`,
which sets the operator + `flux-cluster` recipients):

```bash
sops --encrypt --encrypted-regex '^(data|stringData)$' --in-place \
  Hyperion/k8s/apps/<app>/<name>.sops.yaml
```

The Flux Kustomization for the app needs `spec.decryption: { provider: sops,
secretRef: { name: sops-age } }` (the `sops-age` Secret in `flux-system` holds
the cluster's age private key — created out-of-band, never in git).

> **subPath ConfigMap mounts don't hot-update.** Hermes mounts its nginx config
> via `subPath`; a ConfigMap change needs `kubectl rollout restart` to re-mount.

## Add an application

Drop manifests under `apps/`, add an `apps.yaml` Flux Kustomization in
`clusters/hyperion/` (mirroring `infrastructure.yaml`), and reference it from
`clusters/hyperion/kustomization.yaml`. Commit + push; Flux reconciles within
the interval. For Secrets, follow the SOPS encryption form above.

## Hermes (DeepSeek agent)

`apps/hermes/` — gateway + dashboard in one s6-supervised pod
(`ghcr.io/stevengann/hermes-agent:latest`, arm64). The dashboard binds
pod-loopback (`HERMES_DASHBOARD_HOST=127.0.0.1` → no OAuth gate) behind an
nginx **basic-auth** sidecar; only the proxy is on the LB
(`192.168.10.52`). nginx rewrites the upstream `Host` to `localhost:9119`
(the dashboard 400s on any other Host). DeepSeek key + dashboard htpasswd are
SOPS Secrets; `config.yaml` (`provider: deepseek`) is seeded onto the PVC by an
initContainer if absent (so dashboard edits survive). Retrieve the dashboard
password: `sops -d --extract '["stringData"]["DASHBOARD_PASSWORD"]'
apps/hermes/dashboard-auth.sops.yaml`.
