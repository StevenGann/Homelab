# Runbook: TrueNAS NFS Share for Netboot Root

Creates the NFS share that Pi nodes mount as their root filesystem during netboot imaging.

## Steps

### 1. Create the dataset directory

SSH into Monolith and ensure the path exists:

```bash
mkdir -p /mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root
```

### 2. Create the NFS share in TrueNAS

**Shares → NFS → Add**

| Setting | Value |
|---------|-------|
| Path | `/mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root` |
| Networks | `192.168.10.0/24` |
| Maproot User | `root` |
| Maproot Group | `root` |
| Read Only | No |
| Security | `SYS` |

Enable NFSv3 under **Services → NFS → Configure** if not already enabled.

### 3. Set directory ownership

The netboot root is populated by `setup-netboot-root.sh` running as `truenas_admin`.
The directory must be owned by that user:

```bash
sudo chown -R truenas_admin /mnt/App-Storage/Container-Data/k3s-control-plane/netboot-root
```

### 4. Populate the netboot root

From your workstation, run:

```bash
cd ~/GitHub/Homelab/Monolith/k3s-control-plane/netboot
./setup-netboot-root.sh
```

This builds the Alpine arm64 rootfs, deploys it to the NFS share, and copies
`cmdline.txt` to the TFTP root.

## When to Re-run

Re-run `setup-netboot-root.sh` whenever `imaging.sh` is updated.
