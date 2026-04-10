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

## 2. Create the .env file

The compose file expects `K3S_TOKEN` and `CI_PUBLIC_KEY` from a `.env` file (never committed):

```bash
# Generate k3s token
echo "K3S_TOKEN=$(openssl rand -hex 32)" >> .env

# Add the CI deploy public key (the public half of MONOLITH_SSH_KEY)
# Derive it from the private key if you have it locally:
#   ssh-keygen -y -f ~/.ssh/hyperion-ci-deploy
echo "CI_PUBLIC_KEY=<paste public key here>" >> .env
```

Keep a SOPS-encrypted copy of `K3S_TOKEN` in the repo — see the top-level `.sops.yaml`.
`CI_PUBLIC_KEY` is not sensitive (it's a public key) but keep it out of the repo regardless.

## 3. Build and bring up the stack

The `ci-deploy` service is built locally from `Monolith/k3s-control-plane/ci-deploy/`:

```bash
cd /mnt/App-Storage/Container-Data/k3s-control-plane
docker compose up -d
```

Services started:
- `k3s-server` — Kubernetes control plane (port 6443)
- `nginx` — Image HTTP server (port 50011), serves `/mnt/Media-Storage/Infra-Storage/images/`
- `ci-deploy` — Restricted SSH endpoint for CI uploads (port 2222)

## 4. Verify ci-deploy is accepting connections

```bash
# Should print the SSH banner and exit (not "connection refused")
ssh -p 2222 ci@192.168.10.247 echo ok
```

If the key isn't set up yet, you'll get "Permission denied" — that's correct behaviour.
"Connection refused" means the container isn't running.

## 5. Copy kubeconfig to your workstation

```bash
scp truenas_admin@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig/kubeconfig.yaml ~/.kube/config
```

Update the `server:` field if it shows `127.0.0.1` — replace with `192.168.10.247`.
