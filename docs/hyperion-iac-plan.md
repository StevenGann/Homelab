# Hyperion Cluster — Infrastructure as Code Guide

> **Goal:** A fully reproducible k3s cluster where every node's state is defined in code,
> stored in GitHub, and recoverable from scratch. The only irreplaceable elements are the
> data pools on Monolith.

---

## Architecture Overview

```
GitHub Repository (source of truth)
        │
        ├── Packer template → OS image → served by Monolith (HTTP)
        ├── cloud-init templates → per-node identity via USB cidata stick
        ├── Ansible playbooks → post-boot configuration
        └── Flux manifests → k3s workload state (GitOps)

Network
        └── Ubiquiti UCG — router + DHCP server for all VLANs
              ├── Homelab VLAN: 192.168.10.0/24
              └── DHCP options on Homelab VLAN point PXE clients → Monolith

Monolith (192.168.10.??? — TrueNAS Scale)
        ├── dnsmasq container → TFTP only (netboot file serving)
        ├── Nginx container → serves OS image over HTTP
        ├── Docker Compose → k3s control plane (server)
        └── Data pools (the only truly irreplaceable element)

Hyperion (k3s cluster)
        ├── Control plane: k3s server on Monolith (Docker Compose)
        └── 10 × Raspberry Pi worker nodes
              ├── Boot from local SSD (after provisioning)
              ├── Identity from cidata USB stick (hardware-agnostic)
              ├── /var/lib/node-local/ on every node (see Local Storage)
              └── Workloads reconciled by FluxCD from GitHub
```

### Network Layout

Four VLANs, all managed by the Ubiquiti UCG:

| VLAN | Subnet | Purpose |
|------|--------|---------|
| Homelab | 192.168.10.0/24 | Monolith, Pi cluster, infrastructure |
| ??? | ??? | ??? |
| ??? | ??? | ??? |
| ??? | ??? | ??? |

> **TODO:** Fill in remaining VLANs and subnets.

Monolith IP: `192.168.10.???`
Pi node range: `192.168.10.???–???`
MetalLB pool: `192.168.10.???–???`

---

### Node Identity Model

Node identity is carried by the **cidata USB stick**, not the hardware. If a Pi dies:

1. Move the dead node's cidata stick to a replacement Pi
2. Update the DHCP reservation in the UCG UI: swap the old MAC for the new Pi's MAC,
   keeping the same hostname and IP
3. Boot — replacement gets the same hostname and IP as the node it replaced
4. k3s sees the same node name rejoin; no cluster reconfiguration needed

The UCG is the DHCP server for the Homelab VLAN, so IP reservations live in
UniFi, not in dnsmasq. dnsmasq handles TFTP only. A node replacement therefore
requires one update: the MAC in the UCG reservation. Everything else (hostname,
IP, cluster identity) stays the same.

---

## Repository Structure

```
hyperion/
├── README.md
├── packer/
│   └── rpi-base.pkr.hcl          # OS image definition
├── cloud-init/
│   ├── user-data.template.yaml    # Parameterized per-node config
│   └── nodes/
│       ├── pi-node-01/
│       │   ├── meta-data
│       │   └── user-data
│       ├── pi-node-02/
│       │   └── ...
│       └── (one directory per node)
├── ansible/
│   ├── inventory.yaml             # All node IPs and roles
│   ├── bootstrap.yml              # First-run base config
│   └── k3s-agent.yml              # Worker node setup
├── k8s/
│   ├── flux-system/               # FluxCD bootstrap manifests
│   ├── infrastructure/            # MetalLB, ingress, storage, etc.
│   └── apps/                      # Your actual workloads
├── monolith/
│   ├── dnsmasq.conf               # TFTP config (DHCP handled by UCG)
│   ├── nginx.conf                 # Image server config
│   └── docker-compose.yml         # All Monolith services incl. k3s server
└── docs/
    ├── network-layout.md          # IP assignments, VLAN structure, node roster
    └── runbooks/                  # How to do common tasks
```

> **Public repo note:** IP addresses and internal hostnames are mildly sensitive.
> Either accept this tradeoff (common in homelab repos) or use placeholder values
> in committed configs with a local `.env` override file that is `.gitignore`d.
> Never commit secrets — use SOPS encryption (see Secrets section).

---

## Toolchain — Install on Your Workstation

| Tool | Purpose | Install |
|---|---|---|
| **Ansible** | Configuration management | `pip install ansible` |
| **Packer** | OS image building | [packer.io/downloads](https://developer.hashicorp.com/packer/downloads) |
| **kubectl** | Cluster CLI | `apt install kubectl` |
| **Flux CLI** | GitOps management | `curl -s https://fluxcd.io/install.sh \| bash` |
| **age** | Secret encryption key generation | `apt install age` |
| **sops** | Encrypt secrets for Git | [github.com/getsops/sops](https://github.com/getsops/sops) |
| **helm** | Kubernetes package manager | `apt install helm` |

---

## Phase 1 — Do Now (No USB Drives Required)

### Step 1: Create the GitHub Repository

Create a public repo (e.g. `hyperion`) and set up the directory structure above.
Add a `.gitignore` immediately:

```gitignore
# Local overrides
*.local.yaml
.env

# Packer build artifacts
packer/output/
*.img
*.iso

# Ansible retry files
*.retry
```

Commit this skeleton as your first commit. Every subsequent step adds real content.

---

### Step 2: Set Up Monolith Services

All services on Monolith run as Docker containers on TrueNAS Scale. The
`monolith/docker-compose.yml` defines all of them: the k3s control plane,
the TFTP server for netbooting, and the Nginx image server.

**`monolith/docker-compose.yml`:**
```yaml
services:
  k3s-server:
    image: rancher/k3s:latest
    command: server
    privileged: true
    restart: unless-stopped
    environment:
      - K3S_TOKEN=${K3S_TOKEN}
      - K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml
      - K3S_KUBECONFIG_MODE=666
    volumes:
      - k3s-server:/var/lib/rancher/k3s
      - ./kubeconfig:/output
    ports:
      - "6443:6443"      # Kubernetes API
      - "8472:8472/udp"  # Flannel VXLAN

  dnsmasq:
    image: jpillora/dnsmasq
    restart: unless-stopped
    volumes:
      - ./dnsmasq.conf:/etc/dnsmasq.conf:ro
      - /srv/tftp:/srv/tftp:ro
    ports:
      - "69:69/udp"      # TFTP
    cap_add:
      - NET_ADMIN

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /srv/images:/srv/images:ro
    ports:
      - "8080:8080"      # Image serving

volumes:
  k3s-server:
```

**`K3S_TOKEN`** is the shared secret worker nodes use to join. Generate with:
```bash
openssl rand -hex 32
```
Store it in a `.env` file on Monolith (not committed). Encrypt a copy with SOPS
for the repo. The kubeconfig is written to `./kubeconfig/kubeconfig.yaml` — copy
to `~/.kube/config` on your workstation.

---

### Step 3: Configure UCG for PXE Boot

Since the UCG is the DHCP server for the Homelab VLAN, it must tell PXE clients
where to find the TFTP server. dnsmasq does **not** serve DHCP — it serves TFTP
files only.

In the UniFi console, under **Networks → Homelab → DHCP**:
- **TFTP server** (option 66): `192.168.10.???` (Monolith's IP)
- **Boot file** (option 67): `bootcode.bin`

Also configure **static DHCP reservations** for each Pi node (by MAC address).
UniFi requires a MAC for reservations — see the Node Identity Model section above
for the replacement procedure.

| Hostname | MAC | IP |
|----------|-----|----|
| pi-node-01 | `??:??:??:??:??:??` | `192.168.10.???` |
| pi-node-02 | `??:??:??:??:??:??` | `192.168.10.???` |
| ... | ... | ... |

> **TODO:** Fill in MACs and IPs once the Pi network range is decided.

---

### Step 4: Configure dnsmasq for TFTP

dnsmasq runs in a container on Monolith and serves TFTP files only.
DHCP is handled entirely by the UCG.

**`monolith/dnsmasq.conf`:**
```conf
# No DNS
port=0

# No DHCP — UCG handles it
# TFTP only
enable-tftp
tftp-root=/srv/tftp
```

Populate `/srv/tftp` on Monolith with the Raspberry Pi netboot files
(kernel, initrd, boot firmware from `rpi-eeprom` and the Pi firmware package).

---

### Step 5: Set Up Nginx on Monolith to Serve the OS Image

**`monolith/nginx.conf`:**
```nginx
server {
    listen 8080;
    root /srv/images;
    autoindex on;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

Place your Packer-built `.img` in `/srv/images/`. On a local gigabit network,
a 2GB image transfers in roughly 15 seconds.

---

### Step 6: Build Your Base OS Image with Packer

Packer defines your OS image as code. The output is a binary image file served
by Monolith. The *template* (not the binary) lives in Git.

Your `packer/rpi-base.pkr.hcl` should bake in:

- Raspberry Pi OS Lite (64-bit) as the base
- SSH enabled with your public key
- cloud-init installed and enabled
- Standard packages (curl, jq, git, nfs-common, etc.)
- k3s binary pre-downloaded (saves time during provisioning)
- Timezone and locale set
- Kernel parameters required by k3s:
  ```
  cgroup_memory=1 cgroup_enable=memory
  ```
- Creation of `/var/lib/node-local/` directory (always present — see Local Storage)

Build the image and copy the resulting `.img` to Monolith's `/srv/images/`.
Rebuild and re-copy whenever you want to update the base config.

---

### Step 7: Write Your Ansible Playbooks

Ansible playbooks are idempotent — running them twice produces the same result
as running them once. This is the core property that makes IaC trustworthy.

**`ansible/inventory.yaml`:**
```yaml
all:
  children:
    k3s_agents:
      hosts:
        pi-node-01:
          ansible_host: 192.168.10.???
        pi-node-02:
          ansible_host: 192.168.10.???
        # ... etc for all 10 nodes
  vars:
    ansible_user: pi
    ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

**`ansible/bootstrap.yml`** — runs on every node after first boot:
- Confirm hostname
- Set timezone
- Apply any kernel parameters not baked into the image
- Ensure SSH hardening (disable password auth, etc.)
- Update packages

**`ansible/k3s-agent.yml`** — all Pi nodes:
- Install k3s agent
- Join cluster using Monolith's IP and token
- Apply any node labels

Test idempotency by running a playbook twice. If the second run shows all tasks
as `ok` (no `changed`), it's correct.

---

## Phase 2 — Requires USB Drives

### Step 8: Prepare cidata USB Sticks

One USB stick per node. Any size works — even 512MB.

**Format:** FAT32, volume label must be exactly `cidata`

**Files on each stick:**

`meta-data`:
```yaml
instance-id: pi-node-03
local-hostname: pi-node-03
```

`user-data` (shared template — hostname comes from meta-data):
```yaml
#cloud-config

users:
  - name: pi
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... your-public-key
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

write_files:
  - path: /etc/k3s-token
    permissions: '0600'
    content: |
      YOUR_K3S_TOKEN_HERE

  - path: /usr/local/bin/k3s-join.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      curl -sfL https://get.k3s.io | \
        K3S_URL=https://192.168.10.???:6443 \
        K3S_TOKEN=$(cat /etc/k3s-token) \
        sh -

  - path: /usr/local/bin/setup-node-local.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # /var/lib/node-local is always present (created by Packer image).
      # If a USB HDD is attached, mount it and bind-mount to node-local
      # so the directory is transparently backed by the HDD.
      # Either way the path is the same — workloads don't need to care.
      USB_HDD=$(lsblk -o NAME,TRAN,TYPE -J | jq -r '
        .blockdevices[] |
        select(.tran=="usb" and .type=="disk") |
        .name' | head -1)
      if [ -n "$USB_HDD" ]; then
        mkdir -p /mnt/hdd
        mount /dev/${USB_HDD}1 /mnt/hdd
        echo "/dev/${USB_HDD}1 /mnt/hdd ext4 defaults,nofail 0 2" >> /etc/fstab
        # Bind-mount HDD onto the standard path
        mkdir -p /mnt/hdd/node-local
        mount --bind /mnt/hdd/node-local /var/lib/node-local
        echo "/mnt/hdd/node-local /var/lib/node-local none bind,nofail 0 0" >> /etc/fstab
        touch /etc/node-has-storage-hdd
      fi

runcmd:
  - /usr/local/bin/setup-node-local.sh
  - /usr/local/bin/k3s-join.sh
```

> Keep a copy of each node's `meta-data` in `cloud-init/nodes/<hostname>/` in
> the repo. The `user-data` template is shared — only `meta-data` differs per
> node. The k3s token in `user-data` should be encrypted with SOPS before
> committing (see Secrets section).

**Node replacement procedure:**
1. Move the dead node's cidata stick to the replacement Pi
2. Update the MAC address in the UCG DHCP reservation for that hostname
3. Boot — node comes up with the same hostname, IP, and rejoins the cluster

---

### Step 9: Configure EEPROM on Each Pi

One-time physical step per node. Boot each Pi from an SD card and run:

```bash
sudo rpi-eeprom-config --edit
```

Set:
```
BOOT_ORDER=0xf21
```

Right-to-left: `1` = SD/SSD, `2` = network, `f` = loop. After provisioning is
stable, flip to `0xf12` (local first) so a network outage doesn't prevent booting.

```bash
sudo reboot
```

---

### Step 10: Provision Nodes One at a Time

**For each node:**

1. Insert cidata USB stick
2. Wipe the SSD (or boot with blank SSD)
3. Power on — Pi sends DHCP request
4. UCG assigns IP, responds with TFTP server address
5. Pi fetches netboot files from dnsmasq via TFTP
6. Minimal boot environment pulls `.img` from Nginx over HTTP
7. Image written to SSD; Pi reboots from SSD
8. cloud-init reads cidata stick: sets hostname, creates user, runs scripts
9. `setup-node-local.sh` runs — mounts HDD if present, otherwise `/var/lib/node-local` stays as a plain directory
10. `k3s-join.sh` runs — node joins the cluster
11. Node appears in `kubectl get nodes`
12. Run Ansible bootstrap playbook to verify/harden:

```bash
ansible-playbook ansible/bootstrap.yml --limit pi-node-03
```

**Don't move to the next node until this one is clean.**

---

## Phase 3 — GitOps with FluxCD

### Step 11: Bootstrap FluxCD

FluxCD watches your GitHub repo and reconciles the cluster to match.

```bash
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=hyperion \
  --branch=main \
  --path=k8s/flux-system \
  --personal
```

Flux installs itself into the cluster and commits its own manifests to your repo.
From this point, `git push` is how you deploy.

---

### Step 12: Migrate Workloads to Git

For each service:

1. Write Kubernetes manifests in `k8s/apps/`
2. Commit and push
3. Flux detects the change and applies it
4. Verify with `kubectl get pods`

Nothing should run on the cluster that isn't in Git. `kubectl apply` manually
and Flux will eventually overwrite it — correct behavior. Git wins.

**Example structure for an app:**
```
k8s/apps/
└── my-app/
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── kustomization.yaml
```

---

## Local Storage

Every node has `/var/lib/node-local/`. Its backing differs by hardware:

| Node type | `/var/lib/node-local/` backed by |
|-----------|----------------------------------|
| Plain Pi  | Local SSD (small, ephemeral-safe) |
| Pi + HDD  | USB HDD bind-mounted here |

This path is **excluded from any shared/distributed filesystem** — it is
intentionally node-local and not replicated or exported. It is suitable for:

- In-progress downloads
- Large caches
- Any data where loss is acceptable

Workloads that need this storage use the `storage: local` node label and taint
(applied automatically by the startup script on HDD-equipped nodes):

```yaml
nodeSelector:
  storage: local
tolerations:
  - key: storage
    operator: Equal
    value: local
    effect: NoSchedule
```

Nodes without an HDD are untainted — general workloads schedule on them normally.

---

## Handling Secrets

Never commit plaintext secrets to Git. Use **SOPS + age**:

```bash
age-keygen -o ~/.config/sops/age/keys.txt
```

**`.sops.yaml` in repo root:**
```yaml
creation_rules:
  - path_regex: k8s/.*secret.*\.yaml
    age: age1yourpublickeyhere...
  - path_regex: cloud-init/.*user-data.*
    age: age1yourpublickeyhere...
```

**Encrypt a file:**
```bash
sops --encrypt --in-place k8s/apps/my-app/secret.yaml
```

Flux has native SOPS support — point it at your age key (stored as a cluster
secret) and it decrypts on apply. Your private key lives only on your workstation
and a secure backup.

---

## The Reproducibility Test

At any point, you should be able to answer yes to all of these:

- [ ] If Monolith lost its OS drive (but data pools survived), could you rebuild
      its services by running `docker compose up` from the repo?
- [ ] If a Pi node died, could you replace it by moving the cidata stick, updating
      one DHCP reservation in UniFi, and powering on a blank Pi?
- [ ] If you ran `ansible-playbook bootstrap.yml` against a healthy node, would it
      make zero changes?
- [ ] Is every workload running on the cluster defined in a file in your GitHub repo?
- [ ] Are all secrets either encrypted with SOPS or stored outside the repo?

When all five are yes, you have a genuine IaC homelab.

---

## Guiding Principle

> At every step, ask: *"If I had to rebuild this from scratch,
> what would I need?"*
> If the answer is anything other than
> *"clone the repo and run a command,"*
> that step isn't finished yet.
