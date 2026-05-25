# Heimdall — k3s control plane

Replacement for the broken k3s server on Akasha (formerly Monolith). Runs
as a Docker container on Heimdall (`192.168.10.4`). Hyperion workers
register against `https://192.168.10.4:6443`.

| | |
|---|---|
| Image | `rancher/k3s:v1.34.5-k3s1` (aligned with nixpkgs nixos-25.11 worker k3s) |
| API | `https://192.168.10.4:6443` |
| Flannel | UDP/8472 (VXLAN backend, default) |
| State | `/opt/Homelab/Heimdall/k3s-control-plane/server/` (etcd-equivalent + manifests) |
| Kubeconfig | `/opt/Homelab/Heimdall/k3s-control-plane/kubeconfig/kubeconfig.yaml` |
| Token source | `Heimdall/secrets/k3s-control-plane.sops.env` (SOPS+age) |

The control plane is **temporary on Heimdall**. Once Hyperion is operational
under workloads, a follow-up pipeline decides whether to move the control
plane onto the cluster itself or formally adopt Heimdall. State lives under
one root so re-migration is `rsync + swap IP + redeploy`.

## Initial mint (one-time)

The join token must exist in two places — Heimdall's `.env` (this stack)
and Hyperion's sops-nix secret (workers). Both must hold the **same**
plaintext token, encrypted to different recipient sets.

On the workstation:

**Important:** sops walks up from **cwd** to find `.sops.yaml`, not from
the input file path. So run each `sops` invocation from inside the host
directory that owns the relevant `.sops.yaml`.

```bash
# Mint a 32-byte hex token (64 chars). $TOKEN stays in the shell only
# briefly — encrypted into both files, then unset.
TOKEN=$(openssl rand -hex 32)

# 1. Heimdall side — encrypt to the operator key only.
cd ~/GitHub/Homelab/Heimdall
printf 'K3S_TOKEN=%s\n' "$TOKEN" > secrets/k3s-control-plane.sops.env
sops --encrypt --input-type dotenv --output-type dotenv --in-place \
    secrets/k3s-control-plane.sops.env

# 2. Hyperion side — encrypt to operator + every per-node age key.
cd ~/GitHub/Homelab/Hyperion
mkdir -p nixos/secrets
printf 'k3s-token: %s\n' "$TOKEN" > nixos/secrets/common.yaml
sops --encrypt --in-place nixos/secrets/common.yaml

# Drop the plaintext from the shell.
unset TOKEN

# Commit the two encrypted files.
cd ~/GitHub/Homelab
git add Heimdall/secrets/k3s-control-plane.sops.env Hyperion/nixos/secrets/common.yaml
git commit -m "feat: mint k3s control-plane join token"
```

## Deploy

```bash
# On the workstation. deploy.sh decrypts on the workstation, ships cleartext
# via SSH, then runs `docker compose pull && up -d` for all three stacks
# (root Heimdall, hyperion/, k3s-control-plane/).
bash Heimdall/scripts/deploy.sh
```

Verify on Heimdall:

```bash
ssh owner@192.168.10.4 'docker compose -f /opt/Homelab/Heimdall/k3s-control-plane/docker-compose.yml ps'
ssh owner@192.168.10.4 'sudo curl -k https://localhost:6443/readyz'    # should print "ok"
```

## Getting kubectl access (workstation)

```bash
# Fetch the kubeconfig and rewrite its server URL so kubectl on the
# workstation can reach the cluster via the LAN IP.
ssh owner@192.168.10.4 'sudo cat /opt/Homelab/Heimdall/k3s-control-plane/kubeconfig/kubeconfig.yaml' \
    | sed 's|server: https://127.0.0.1:6443|server: https://192.168.10.4:6443|' \
    > ~/.kube/heimdall.yaml
chmod 600 ~/.kube/heimdall.yaml

KUBECONFIG=~/.kube/heimdall.yaml kubectl get nodes
```

## Rotating the join token

Each Hyperion worker also has the token embedded via sops-nix; rotating
means re-encrypting both sides and re-deploying everything.

```bash
TOKEN=$(openssl rand -hex 32)

cd ~/GitHub/Homelab/Heimdall
printf 'K3S_TOKEN=%s\n' "$TOKEN" > secrets/k3s-control-plane.sops.env
sops --encrypt --input-type dotenv --output-type dotenv --in-place \
    secrets/k3s-control-plane.sops.env

cd ~/GitHub/Homelab/Hyperion
printf 'k3s-token: %s\n' "$TOKEN" > nixos/secrets/common.yaml
sops --encrypt --in-place nixos/secrets/common.yaml
unset TOKEN

cd ~/GitHub/Homelab
git add Heimdall/secrets/ Hyperion/nixos/secrets/
git commit -m "chore: rotate k3s join token"

# Re-deploy Heimdall control plane
bash Heimdall/scripts/deploy.sh

# Re-deploy every worker (Colmena picks up the new sops secret)
cd Hyperion/nixos && colmena apply --on '@hyperion-*' --parallel 4
```

## Troubleshooting

**k3s-server container restarts repeatedly.** Most common cause: the
token literal in `/opt/Homelab/Heimdall/k3s-control-plane/.env` is empty
or mismatched. Check `docker compose logs k3s-server` on Heimdall.

**Workers don't appear in `kubectl get nodes`.** Check the worker's
`journalctl -u k3s -f`. Most common cause: token mismatch (Hyperion side
re-encrypted but workers haven't rebuilt) or `192.168.10.4:6443` not
reachable (`nftables` on Heimdall didn't open the port; see
`Heimdall/hostconf/nftables.conf`).

**Cannot decrypt kubeconfig on workstation.** The kubeconfig isn't
encrypted; it's owned by `root:root` mode `644` on Heimdall. Use `sudo`
when reading via SSH.

## File layout

```
Heimdall/k3s-control-plane/
├── README.md              ← this file
├── docker-compose.yml     ← the k3s-server service spec
└── .env.example           ← example env vars
```

Runtime state on Heimdall:

```
/opt/Homelab/Heimdall/k3s-control-plane/
├── .env                   ← shipped by deploy.sh (0600, root:root, gitignored)
├── server/                ← /var/lib/rancher/k3s (etcd-equivalent)
└── kubeconfig/
    └── kubeconfig.yaml    ← admin kubeconfig (0644, points at localhost)
```
