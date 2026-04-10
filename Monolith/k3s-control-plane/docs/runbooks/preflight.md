# Pre-flight: k3s Control Plane on Monolith

Before running `docker compose up` for the first time:

## 1. Create required directories

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/{images,kubeconfig}
```

- `images/` — nginx image root (Node IMG and Bootstrap IMG served from here)
- `kubeconfig/` — k3s writes kubeconfig here on startup

## 2. Create image subdirectories

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/images/{node,bootstrap}
```

## 3. Create the .env file

The compose file expects `K3S_TOKEN` from a `.env` file (never committed):

```bash
echo "K3S_TOKEN=$(openssl rand -hex 32)" > .env
```

Keep a SOPS-encrypted copy in the repo — see the top-level `.sops.yaml`.

## 4. Install the CI deploy handler

GitHub Actions uploads images and updates the manifest via a restricted SSH key.
Install the handler script that enforces what the CI key can do:

```bash
sudo tee /usr/local/bin/ci-deploy-handler.sh > /dev/null << 'EOF'
#!/bin/bash
case "$SSH_ORIGINAL_COMMAND" in
  rsync\ --server*)
    exec rsync --server "$@"
    ;;
  "update-manifest node "*)
    MANIFEST="${SSH_ORIGINAL_COMMAND#update-manifest node }"
    echo "$MANIFEST" > ~/images/node/manifest.json
    ;;
  "update-symlink node "*)
    IMG="${SSH_ORIGINAL_COMMAND#update-symlink node }"
    ln -sf "$IMG" ~/images/node/rpi-node-latest.img.zst
    ;;
  prune-node-images)
    ls -t ~/images/node/*.img.zst 2>/dev/null | tail -n +4 | xargs -r rm -f
    ;;
  *)
    echo "Forbidden command" >&2; exit 1
    ;;
esac
EOF
sudo chmod +x /usr/local/bin/ci-deploy-handler.sh
```

Add the CI deploy key to `~/.ssh/authorized_keys`:

```bash
echo "command=\"/usr/local/bin/ci-deploy-handler.sh\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding <CI_PUBLIC_KEY>" >> ~/.ssh/authorized_keys
```

Replace `<CI_PUBLIC_KEY>` with the contents of the `MONOLITH_SSH_KEY` public key
(the key generated for GitHub Actions).

## 5. Bring up the stack

```bash
cd /mnt/App-Storage/Container-Data/k3s-control-plane
docker compose up -d
```

## 6. Copy kubeconfig to your workstation

```bash
scp truenas_admin@192.168.10.247:/mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig/kubeconfig.yaml ~/.kube/config
```

Update the `server:` field if it shows `127.0.0.1` — replace with `192.168.10.247`.
