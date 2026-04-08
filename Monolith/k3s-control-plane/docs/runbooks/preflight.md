# Pre-flight: k3s Control Plane on Monolith

Before running `docker compose up` for the first time:

## 1. Create the kubeconfig output directory

Docker will create the kubeconfig mount target as root if it doesn't exist, which
prevents k3s from writing into it. Create it manually first:

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig
```

## 2. Create the .env file

The compose file expects `K3S_TOKEN` from a `.env` file (never committed). Generate
and write it once:

```bash
echo "K3S_TOKEN=$(openssl rand -hex 32)" > .env
```

Keep a SOPS-encrypted copy in the repo — see the top-level `.sops.yaml`.

## 3. Verify host paths exist

The compose file mounts the following paths from the TrueNAS dataset:

```
/mnt/App-Storage/Container-Data/k3s-control-plane/tftp/      → dnsmasq TFTP root
/mnt/App-Storage/Container-Data/k3s-control-plane/images/    → nginx image root
/mnt/App-Storage/Container-Data/k3s-control-plane/kubeconfig/ → k3s kubeconfig output
```

Create any that don't exist before bringing the stack up:

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/{tftp,images,kubeconfig}
```

## 4. Bring up the stack

```bash
docker compose up -d
```

## 5. Copy kubeconfig to your workstation

```bash
scp monolith:/path/to/k3s-control-plane/kubeconfig/kubeconfig.yaml ~/.kube/config
```

Update the `server:` field in the kubeconfig if it shows `127.0.0.1` — replace
with `192.168.10.247`.
