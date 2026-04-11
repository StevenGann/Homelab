# Homelab IaC

Infrastructure as Code for a home Kubernetes cluster. Every host's state is
defined in this repository and recoverable from scratch.

---

## Repository Structure

```
Homelab/
├── docs/                        # Project-wide documentation
│   ├── todo.md                  # Current task list and next steps
│   └── design/                  # Architecture planning documents
│
├── Hyperion/                    # Pi 5 k3s worker cluster (10 nodes)
│   ├── packer/                  # OS image definitions (Bootstrap IMG + Node IMG)
│   │   ├── rpi-bootstrap.pkr.hcl  # Bootstrap SD card image
│   │   ├── rpi-node.pkr.hcl       # Production NVMe image
│   │   └── files/               # Runtime scripts and systemd units baked in
│   ├── ansible/                 # Post-boot configuration and hardening
│   ├── k8s/                     # Kubernetes manifests (FluxCD GitOps)
│   ├── flash-identity-usb.sh    # Formats per-node identity USB sticks
│   ├── reimage.sh               # Reboots running nodes into Bootstrap SD
│   ├── publish-image.sh         # Manual build-and-publish (pre-CI use)
│   ├── configure-eeprom.sh      # Sets BOOT_ORDER on all nodes via SSH
│   └── docs/runbooks/           # Hyperion-specific runbooks
│
└── Monolith/                    # TrueNAS Scale host (192.168.10.247)
    └── k3s-control-plane/       # k3s server + nginx image server
        ├── docker-compose.yml
        ├── nginx.conf
        ├── ci-deploy/           # GitHub Releases poller (downloads images to Monolith)
        ├── healthcheck/         # IaC integration test runner (HTTP API on port 50012)
        └── docs/runbooks/
```

Each top-level directory maps to a physical host or cluster. Files for Monolith
go under `Monolith/`, files for the Pi cluster go under `Hyperion/`. This pattern
extends as IaC coverage expands to other hosts.

---

## Infrastructure Overview

```
Workstation
  └── Git push → GitHub → CI builds images automatically

Monolith (TrueNAS Scale — 192.168.10.247)
  ├── k3s server (Docker Compose)
  ├── nginx → HTTP image server (port 50011)
  │     ├── /node/manifest.json         (current Node IMG version + SHA256)
  │     ├── /node/rpi-node-<ver>.img    (decompressed Node IMGs, 3 kept)
  │     └── /bootstrap/rpi-bootstrap.img  (Bootstrap SD card image)
  ├── ci-deploy → polls GitHub Releases, downloads + decompresses images
  └── healthcheck → IaC integration tests (port 50012)

Hyperion Cluster (k3s)
  ├── Control plane: k3s server on Monolith
  └── 10 × Raspberry Pi 5 worker nodes (192.168.10.101–.110)
        ├── Boot: PCIe NVMe SSD (256GB) — p1 firmware, p2 root (32GB), p3 storage (~220GB)
        ├── Identity: HYPERION-ID USB stick (hostname file, Node IMG cache)
        └── Workloads: reconciled by FluxCD from this repo
```

### Node imaging flow

```
Bootstrap SD card inserted
  └── hyperion-bootstrap.service runs on every boot
        ├── Check Monolith for newer Node IMG → update HYPERION-ID USB cache
        ├── Compare USB cache version vs NVMe version
        ├── If NVMe is behind → dd NVMe from USB cache → repartition → reboot
        └── If NVMe is current → reboot into NVMe immediately

NVMe boot (production)
  ├── apply-identity.service → reads hostname from HYPERION-ID USB → hostnamectl
  └── detect-node-storage.service → mounts best storage device to /mnt/node-storage
```

### Network

All infrastructure is on the Homelab VLAN (`192.168.10.0/24`):

| Range | Purpose |
|-------|---------|
| `.10–.99` | MetalLB LoadBalancer pool |
| `.101–.110` | Hyperion Pi nodes |
| `.247` | Monolith |

---

## Provisioning a New Cluster from Scratch

See `docs/todo.md` for current status and step-by-step checklist. High-level flow:

1. **Monolith** — deploy `Monolith/k3s-control-plane/docker-compose.yml`
   - See `Monolith/k3s-control-plane/docs/runbooks/preflight.md`
2. **CI secrets** — configure GitHub Actions secrets for image publishing
3. **Build images** — CI builds on push, or run `Hyperion/publish-image.sh` manually
   - See `Hyperion/docs/runbooks/build-packer-image.md`
4. **EEPROM** — set boot order on each Pi (`./configure-eeprom.sh --reboot`)
   - See `Hyperion/docs/runbooks/configure-eeprom.md`
5. **Identity USBs** — flash one per node (`./flash-identity-usb.sh /dev/sdX hyperion-<name>`)
6. **Bootstrap SD** — flash once, share across nodes (`dd` the Bootstrap IMG)
7. **Image nodes** — insert SD + USB per node, power on, Bootstrap handles the rest
8. **Ansible** — `ansible-playbook bootstrap.yml` after nodes are on NVMe
9. **FluxCD** — bootstrap GitOps
   ```bash
   flux bootstrap github --owner=<user> --repository=Homelab --path=Hyperion/k8s/flux-system
   ```

---

## Re-imaging a Node

```bash
# Insert Bootstrap SD card into the node, then:
cd ~/GitHub/Homelab/Hyperion
./reimage.sh hyperion-alpha    # or: ./reimage.sh all
# Node reboots, Bootstrap SD updates USB cache and reflashes NVMe automatically.
# Remove SD card after node is back on NVMe.
```

CI publishes a new Node IMG on every push to `main` touching `Hyperion/packer/`.

---

## Secrets

Secrets are encrypted with SOPS + age. The age public key is in
`Hyperion/.sops.yaml`. The private key lives only on the workstation at
`~/.config/sops/age/keys.txt` — never committed.

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>
```

---

## Reproducibility Checklist

- [ ] Monolith services restored from `docker compose up` alone
- [ ] Dead node replaced by inserting Bootstrap SD + running `./reimage.sh`
- [ ] `ansible-playbook bootstrap.yml` against a healthy node makes zero changes
- [ ] Every workload running in the cluster is defined in `Hyperion/k8s/`
- [ ] All secrets are SOPS-encrypted or stored outside the repo
