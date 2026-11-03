# Embeddings service

The in-cluster embedding backend for Bifrost. Replaces the Epsilon workstation
(RTX 4080, house subnet), which was never reliable enough to depend on.

- **Manifest:** `Hyperion/k8s/apps/bifrost/embeddings.yaml` (Deployment + Service)
- **Namespace / Service:** `bifrost` / `embeddings.bifrost.svc.cluster.local:11434`
- **Image:** `ollama/ollama:0.40.14` (multi-arch; the cluster is arm64)
- **Model:** `nomic-embed-text`, 768 dimensions, 274 MB, pulled at pod start
- **Wired in Bifrost as:** backend `local`, route `embed` → `local/nomic-embed-text`

## Why this shape

ADRs for the alternative designs are worth recording because each was measured
or checked, not guessed.

- **CPU is enough.** The workload is a 137M-parameter embedding model. On one
  4-core ARM worker it measured 0.07 s per 30-word chunk (15/s), 0.26 s per
  150-word chunk (3.8/s), 1.19 s per 600-word chunk, and 17 chunks/s when 16
  short inputs arrive in one batched request. Peak memory ~680 MB. A full
  re-index of a 10k-chunk vault is roughly 45 minutes.
- **TEI is not available.** Hugging Face's text-embeddings-inference is the
  stronger CPU server, but its published CPU images are `amd64` only (checked
  `cpu-1.8.2` and `cpu-latest` in the registry manifest). Building it for arm64
  is possible and unnecessary at this size.
- **No custom microservice.** The server is stateless, so "parallel across
  nodes" is just `replicas`; the Service load-balances and the scheduler spreads.
  A sharding service would reimplement the Service object. If bulk indexing ever
  needs more, fan the chunks out from the indexing Job across replicas.
- **No local chat model.** qwen2.5:7b on four ARM cores is single-digit tokens
  per second. `private:local` was removed from Bifrost's `ROUTES` rather than
  left as a route that can only fail. Re-add it if a CPU chat model ever becomes
  usable.

## Operating it

```bash
export KUBECONFIG=/opt/data/k3s.yaml
K=/opt/data/kubectl

# health and placement
$K -n bifrost get deploy,pod -l app=embeddings -o wide
$K -n bifrost logs deploy/embeddings -c embeddings --tail=50
$K -n bifrost logs deploy/embeddings -c pull-model --tail=20

# what the model server has loaded
$K -n bifrost exec deploy/embeddings -c embeddings -- ollama list

# end-to-end through Bifrost (needs a tenant key)
curl -s -X POST http://bifrost.lab:11434/v1/embeddings \
  -H "Authorization: Bearer <bk_...>" -H 'Content-Type: application/json' \
  -d '{"model":"embed","input":"test"}' | head -c 200
```

A cold pod takes about 10–15 s to become ready: the init container starts a
temporary server and pulls the model, then the real container starts and loads
it. `OLLAMA_KEEP_ALIVE=-1` keeps the model resident, so a warm call is ~70 ms
for a short chunk. Resource requests are 500m/1Gi, limits 2Gi memory.

## Changing the model

Edit the `ollama pull` argument in `embeddings.yaml`, then update Bifrost's
`embed` route in `configmap.yaml`. **Check the output dimensions first:** a
model with a different dimension invalidates every stored vector. Nothing
currently stores embeddings (the semantic cache has never recorded a hit), so a
switch is free today — it will not be once something does.

Pull failures are visible as an init container in `Init:Error` with the registry
error in its logs. The pull needs egress to `registry.ollama.ai`; the image
itself comes from Docker Hub.
