# Runbook: Provision a Hyperion Node

Covers the full process of provisioning a single Pi 5 node from scratch:
netboot → image → cloud-init → Ansible hardening → cluster join.

Do nodes one at a time. Verify each node is healthy before moving to the next.

---

## Prerequisites

- cidata USB stick for this node is flashed (see `flash-cidata-sticks.md`)
- EEPROM boot order is set to `0xf21` (network first) — see `configure-eeprom.md`
- Monolith stack is running (`docker compose ps` shows all three containers up)
- TFTP root is populated with Pi 5 boot files
- Netboot root is deployed (`setup-netboot-root.sh` has been run)
- Packer image is present at `/mnt/App-Storage/Container-Data/k3s-control-plane/images/rpi-base.img`

---

## Step 1: Boot the Node

1. Insert the node's cidata USB stick
2. Connect ethernet (PoE provides power)
3. Power on (or reboot if already running)

The node will:
1. Send a DHCP request → UCG assigns its static IP, returns TFTP server address
2. Fetch boot files from dnsmasq on Monolith via TFTP
3. Mount the NFS netboot root from Monolith
4. Run `/init` → brings up networking → runs `imaging.sh`

Monitor progress on the network KVM.

---

## Step 2: Watch the Imaging Script

Via the KVM you should see:

```
=============================================
  Hyperion Node Imaging Script
  Target: /dev/nvme0n1
  Image:  http://192.168.10.247:50011/rpi-base.img
=============================================
[HH:MM:SS] [IMAGER] Network ready.
[HH:MM:SS] [IMAGER] Step 1/5: Flashing image to /dev/nvme0n1
[HH:MM:SS] [IMAGER] Step 2/5: Disabling root partition auto-expansion
[HH:MM:SS] [IMAGER] Step 3/5: Resizing root partition (p2) to 32GiB
[HH:MM:SS] [IMAGER] Step 4/5: Creating node-storage partition (p3)
[HH:MM:SS] [IMAGER] Step 5/5: Updating /etc/fstab
[HH:MM:SS] [IMAGER] Imaging complete — rebooting in 5 seconds
```

**Expected duration:** ~3–5 minutes (image download + flash over gigabit).

If the script fails, the KVM will show the error. Common issues:
- Can't reach Monolith → check dnsmasq container is running, check DHCP option 66
- Image download fails → check nginx container is running on port 50011
- Partition errors → check NVMe is detected (`lsblk` in the imaging env)

---

## Step 3: First Boot from NVMe

After imaging, the node reboots from NVMe. cloud-init runs and:
- Sets hostname from the cidata stick's `meta-data`
- Creates the `pi` user with your SSH key
- Writes `/etc/k3s-token`
- Runs `setup-node-local.sh` → mounts USB HDD to `/mnt/node-storage` if present,
  otherwise `/mnt/node-storage` is backed by `nvme0n1p3`
- Runs `k3s-join.sh` → node joins the cluster

Wait ~2 minutes for cloud-init to complete, then verify the node appears:

```bash
kubectl get nodes
```

The node should appear as `Ready` (may take another minute for k3s to register).

---

## Step 4: Run Ansible Bootstrap

From your workstation:

```bash
cd ~/GitHub/Homelab/Hyperion
ansible-playbook ansible/bootstrap.yml --limit <hostname>
# Example:
ansible-playbook ansible/bootstrap.yml --limit hyperion-alpha
```

This verifies and hardens the node:
- Confirms hostname
- Sets timezone to UTC
- Verifies cgroup kernel parameters
- Updates packages
- Hardens SSH (disables password auth, disables root login)
- Ensures `/mnt/node-storage` exists

A fully idempotent run shows all tasks as `ok` with zero `changed`. If it's the
first run, expect some `changed` entries.

---

## Step 5: Restore EEPROM Boot Order

SSH into the node and restore the permanent boot order:

```bash
ssh pi@192.168.10.10x
sudo rpi-eeprom-config --edit
# Set: BOOT_ORDER=0xf416
sudo reboot
```

This ensures the node boots from NVMe on future power cycles, only falling back
to network if the NVMe has no bootable OS.

---

## Step 6: Verify and Move On

```bash
kubectl get nodes -o wide
```

Confirm the node is `Ready` and showing the correct IP. Then move to the next node.

---

## Node Hostname → IP Reference

| Hostname | IP |
|----------|----|
| hyperion-alpha | 192.168.10.101 |
| hyperion-beta | 192.168.10.102 |
| hyperion-gamma | 192.168.10.103 |
| hyperion-delta | 192.168.10.104 |
| hyperion-epsilon | 192.168.10.105 |
| hyperion-zeta | 192.168.10.106 |
| hyperion-eta | 192.168.10.107 |
| hyperion-theta | 192.168.10.108 |
| hyperion-iota | 192.168.10.109 |
| hyperion-kappa | 192.168.10.110 |
