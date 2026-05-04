# Pre-flight: k3s Control Plane on Monolith

The stack is managed by **Dockge** on Monolith (TrueNAS Scale). The same stack directory is reachable three different ways depending on what you're doing:

| Access method | Path | Used by |
|---------------|------|---------|
| TrueNAS host filesystem | `/mnt/App-Storage/Container-Data/k3s-control-plane/` | Docker bind-mounts in `docker-compose.yml`, host-side `mkdir` |
| Dockge container view | `/mnt/.ix-apps/app_mounts/dockge/stacks/k3s-control-plane/` | Where Dockge runs `docker compose ...` |
| SMB share | `smb://monolith.local/container-data/k3s-control-plane/` | Operator file edits from a workstation |

All three reference the same data; pick whichever is convenient.

Before bringing the stack up for the first time:

## 1. Create required directories

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig
mkdir -p /mnt/Media-Storage/Infra-Storage/images/{node,bootstrap}
mkdir -p /mnt/Media-Storage/Infra-Storage/journal-remote
```

- `kubeconfig/` — k3s writes kubeconfig here on startup
- `images/node/` — Node IMG files served by nginx; written by the ci-deploy container
- `images/bootstrap/` — Bootstrap IMG files served by nginx; written by the ci-deploy container
- `journal-remote/` — receives `systemd-journal-upload` streams from every Hyperion node; one `.journal` per source host

## 2. Place configuration files

Copy `nginx.conf` and `docker-compose.yml` from the repo into the stack directory. The simplest path is over SMB from your workstation:

```
smb://monolith.local/container-data/k3s-control-plane/docker-compose.yml
smb://monolith.local/container-data/k3s-control-plane/nginx.conf
```

All container images are pulled from `ghcr.io/stevengann/homelab-*` — no local build contexts are needed in the stack directory. Images are built and published by the workflows under `.github/workflows/build-*-img.yml`.

## 3. Create the .env file

The compose file expects `K3S_TOKEN` and optionally `GITHUB_TOKEN` from a `.env` file (never committed). Edit it via SMB at `smb://monolith.local/container-data/k3s-control-plane/.env`, or via SSH:

```bash
ssh truenas_admin@192.168.10.247
cd /mnt/App-Storage/Container-Data/k3s-control-plane

# Generate k3s cluster token
echo "K3S_TOKEN=$(openssl rand -hex 32)" >> .env

# GitHub token for the ci-deploy poller — leave blank for the public StevenGann/Homelab repo
# (silences the "GITHUB_TOKEN not set" compose warning). For private repos, create a
# fine-grained PAT with read access to Contents at:
# https://github.com/settings/personal-access-tokens
echo "GITHUB_TOKEN=" >> .env
```

Keep a SOPS-encrypted copy of `K3S_TOKEN` in the repo — see the top-level `.sops.yaml`.

## 4. Bring up the stack

In the Dockge UI: open the `k3s-control-plane` stack and click **Start** (or **Update** if it already exists). Dockge runs `docker compose pull && docker compose up -d` against the stack.

For an SSH-based equivalent:

```bash
ssh truenas_admin@192.168.10.247
cd /mnt/.ix-apps/app_mounts/dockge/stacks/k3s-control-plane
docker compose up -d
```

Services started:
- `k3s-server` — Kubernetes control plane (port 6443)
- `nginx` — Image HTTP server (port 50011), serves `/mnt/Media-Storage/Infra-Storage/images/`
- `ci-deploy` — GitHub Releases poller; downloads new Node and Bootstrap images automatically
- `healthcheck` — IaC integration test runner (port 50012); monitors images and node connectivity
- `journal-remote` — `systemd-journal-remote` HTTP receiver (port 19532); accepts `systemd-journal-upload` streams from every Hyperion node into `/mnt/Media-Storage/Infra-Storage/journal-remote/`. Image: `ghcr.io/stevengann/homelab-journal-remote:latest`

### Adding `journal-remote` to a stack that's already running

1. Drop the new `docker-compose.yml` into `smb://monolith.local/container-data/k3s-control-plane/`.
2. Create the bind-mount target on the host: `ssh truenas_admin@192.168.10.247 'mkdir -p /mnt/Media-Storage/Infra-Storage/journal-remote'`.
3. In the Dockge UI for the `k3s-control-plane` stack, click **Update**.

> First-time setup only: the `homelab-journal-remote` package on ghcr.io must be made **public** in the GitHub package settings, the same way `homelab-ci-deploy` and `homelab-healthcheck` were. Otherwise the pull will 401 with "denied: requested access to the resource is denied."
>
> Also one-time: the workflow path filter only fires on changes under `Monolith/k3s-control-plane/journal-remote/**`, so the first publish of the image needs `gh workflow run build-journal-remote-img.yml` (or a manual dispatch from the Actions tab).

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
