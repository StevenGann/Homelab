# Homelab IaC

Infrastructure as Code for a home Kubernetes cluster. Every host's state is
defined in this repository and recoverable from scratch.

---

## Repository Structure

```
Homelab/
├── docs/                        # Project-wide documentation
│   ├── todo.md                  # Current task list and progress
│   └── hyperion-iac-plan.md     # Original architecture planning guide
│
├── Hyperion/                    # Pi 5 k3s worker cluster (10 nodes)
│   ├── packer/                  # OS image definition
│   ├── cloud-init/              # Node identity and first-boot config
│   ├── ansible/                 # Post-boot configuration and hardening
│   ├── k8s/                     # Kubernetes manifests (FluxCD GitOps)
│   └── docs/                    # Hyperion-specific docs and runbooks
│
└── Monolith/                    # TrueNAS Scale host (192.168.10.247)
    └── k3s-control-plane/       # k3s server, TFTP, nginx, netboot
        ├── docker-compose.yml
        ├── netboot/             # NFS root filesystem builder + imaging script
        └── docs/runbooks/
```

Each top-level directory maps to a physical host or cluster. Files for Monolith
go under `Monolith/`, files for the Pi cluster go under `Hyperion/`. This pattern
extends as IaC coverage expands to other hosts.

---

## Infrastructure Overview

```
Workstation
  └── Git push → GitHub (source of truth)

Monolith (TrueNAS Scale — 192.168.10.247)
  ├── k3s server (Docker Compose)
  ├── dnsmasq → TFTP (Pi netboot firmware)
  ├── nginx → HTTP image server (port 50011)
  └── NFS → netboot root filesystem (Alpine + imaging script)

Hyperion Cluster (k3s)
  ├── Control plane: k3s server on Monolith
  └── 10 × Raspberry Pi 5 worker nodes (192.168.10.101–.110)
        ├── Boot: PCIe NVMe SSD (256GB)
        ├── Identity: cidata USB stick (cloud-init NoCloud)
        └── Workloads: reconciled by FluxCD from this repo
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

See `docs/todo.md` for current status. Full process:

1. **Monolith** — deploy `Monolith/k3s-control-plane/docker-compose.yml`
   - See `Monolith/k3s-control-plane/docs/runbooks/preflight.md`
2. **TFTP** — populate Pi 5 boot files
   - See `Monolith/k3s-control-plane/docs/runbooks/populate-tftp.md`
3. **NFS netboot root** — build and deploy Alpine imaging environment
   - See `Monolith/k3s-control-plane/docs/runbooks/setup-nfs-netboot.md`
4. **Packer** — build base OS image and deploy to Monolith
   - See `Hyperion/docs/runbooks/build-packer-image.md`
5. **cidata sticks** — flash one USB stick per node
   - See `Hyperion/docs/runbooks/flash-cidata-sticks.md`
6. **EEPROM** — configure boot order on each Pi
   - See `Hyperion/docs/runbooks/configure-eeprom.md`
7. **Provision nodes** — netboot → image → cloud-init → Ansible → k3s join
   - See `Hyperion/docs/runbooks/provision-node.md`
8. **FluxCD** — bootstrap GitOps
   - `flux bootstrap github --owner=<user> --repository=Homelab --path=Hyperion/k8s/flux-system`

---

## Secrets

Secrets are encrypted with SOPS + age. The age public key is in
`Hyperion/.sops.yaml`. The private key lives only on the workstation at
`~/.config/sops/age/keys.txt` — never committed.

To decrypt for editing:
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt <file>
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --edit <file>
```

---

## Reproducibility Checklist

- [ ] Monolith services restored from `docker compose up` alone
- [ ] Dead node replaced by moving cidata stick + updating UCG MAC reservation
- [ ] `ansible-playbook bootstrap.yml` against a healthy node makes zero changes
- [ ] Every workload running in the cluster is defined in `Hyperion/k8s/`
- [ ] All secrets are SOPS-encrypted or stored outside the repo
