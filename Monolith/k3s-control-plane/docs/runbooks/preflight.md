# Pre-flight: k3s Control Plane on Monolith

Before running `docker compose up` for the first time:

## 1. Create required directories

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig
mkdir -p /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}
```

- `kubeconfig/` — k3s writes kubeconfig here on startup
- `images/node/` — Node IMG files served by nginx; written by the ci-deploy container
- `images/bootstrap/` — Bootstrap IMG files served by nginx; written by the ci-deploy container

## 2. Place configuration files

Copy `nginx.conf` and `docker-compose.yml` from the repo to the compose directory:

```bash
cp Monolith/k3s-control-plane/nginx.conf \
   /mnt/App-Storage/Container-Data/k3s-control-plane/nginx.conf
cp Monolith/k3s-control-plane/docker-compose.yml \
   /mnt/App-Storage/Container-Data/k3s-control-plane/docker-compose.yml
```

## 3. Create the .env file

The compose file expects `K3S_TOKEN` and optionally `GITHUB_TOKEN` from a `.env` file (never committed):

```bash
cd /mnt/App-Storage/Container-Data/k3s-control-plane

# Generate k3s cluster token
echo "K3S_TOKEN=$(openssl rand -hex 32)" >> .env

# GitHub token for the ci-deploy poller (only needed if the repo is private)
# Create a fine-grained PAT with read access to Contents at:
# https://github.com/settings/personal-access-tokens
echo "GITHUB_TOKEN=<paste token here>" >> .env
```

Keep a SOPS-encrypted copy of `K3S_TOKEN` in the repo — see the top-level `.sops.yaml`.

## 4. Bring up the stack

```bash
cd /mnt/App-Storage/Container-Data/k3s-control-plane
docker compose up -d
```

Services started:
- `k3s-server` — Kubernetes control plane (port 6443)
- `nginx` — Image HTTP server (port 50011), serves `/mnt/Media-Storage/Infra-Storage/images/`
- `ci-deploy` — GitHub Releases poller; downloads new Node and Bootstrap images automatically
- `healthcheck` — IaC integration test runner (port 50012); monitors images and node connectivity

## 5. Verify services are healthy

```bash
# All four containers should show "healthy" status
docker compose ps

# Check ci-deploy is polling successfully
cat /mnt/Media-Storage/Infra-Storage/images/ci-deploy-status.json

# Check healthcheck API
curl -s http://localhost:50012/summary | jq .
```

The ci-deploy container polls GitHub Releases every 5 minutes. After the first
successful poll, `ci-deploy-status.json` will contain the last poll timestamp
and current image versions.

## 6. Copy kubeconfig to your workstation

```bash
scp truenas_admin@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig/kubeconfig.yaml ~/.kube/config
```

Update the `server:` field if it shows `127.0.0.1` — replace with `192.168.10.247`.

## Troubleshooting

### ci-deploy not updating images

1. Check container logs: `docker compose logs ci-deploy --tail 50`
2. Verify GitHub token (if repo is private): `docker compose exec ci-deploy env | grep GITHUB_TOKEN`
3. Check status file: `cat /mnt/Media-Storage/Infra-Storage/images/ci-deploy-status.json`
4. Common causes:
   - GitHub API rate limit (anonymous: 60 req/hr, authenticated: 5000 req/hr)
   - No matching release tags (`node-v*` for Node IMG, `bootstrap-latest` for Bootstrap)
   - Network connectivity to `api.github.com`

### healthcheck showing failures

1. Check full results: `curl -s http://localhost:50012/ | jq .`
2. Trigger a manual rescan: `curl -s -X POST http://localhost:50012/scan`
3. Common causes:
   - `nginx_reachable` fail: nginx container not running or port mismatch
   - `node_manifest_valid` fail: ci-deploy hasn't completed first poll yet
   - `node_ssh_*` fail: nodes not yet imaged or not on the network
