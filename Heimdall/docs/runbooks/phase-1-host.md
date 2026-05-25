# Phase 1 — Host setup

> **Goal:** bring a fresh Ubuntu Server 26.04 LTS install to the point where the
> Heimdall stack is ready to be deployed in Phase 2. At the end of Phase 1 no
> Heimdall-stack containers are running yet; the host has Docker CE, nftables,
> systemd-resolved configured for port 53 to be free, journal-upload pointed at
> Akasha, and the Komodo Periphery agent installed as a systemd service.

## Prerequisites

- Hardware racked and on the network (per `Heimdall/README.md`).
- A workstation with SSH access to the LAN.
- A user account `owner` on the target with `sudo` and an authorized SSH pubkey.
- SOPS age private key on the workstation at `~/.config/sops/age/keys.txt`.

## Steps

### 1. Install Ubuntu Server 26.04 LTS

Boot from the Ubuntu Server 26.04 LTS USB installer. Install with:

- Hostname: `heimdall`
- User: `owner` with workstation SSH pubkey added during install
- Storage: default layout, no swap on ZFS, OpenSSH server
- Network: any interface DHCP for the installer; static IP is configured by `setup.sh` in step 3
- No snaps beyond what the installer requires

Reboot. SSH from the workstation:

```bash
ssh owner@<dhcp-ip-from-installer>
```

### 2. Audit and run `setup.sh`

The script lives in this repo at `Heimdall/scripts/setup.sh`. Fetch and audit it before running (two-step pattern; iter-1 known concern #12):

```bash
curl -fsSL https://raw.githubusercontent.com/StevenGann/Homelab/main/Heimdall/scripts/setup.sh -o /tmp/setup.sh
less /tmp/setup.sh                  # audit before running
sudo bash /tmp/setup.sh
```

The script is idempotent — re-running on a partially-configured host is safe. Per-step markers live under `/var/lib/heimdall-setup/<step>.done`. Force a single step to re-run with:

```bash
sudo bash /tmp/setup.sh --force 04_nftables
```

What it does:

1. APT base packages + Docker CE from the upstream `download.docker.com` repo
2. Netplan static `192.168.10.4`
3. systemd-resolved with `DNSStubListener=no`; `/etc/resolv.conf` symlinked to upstream view
4. nftables ruleset (default-deny inbound, allow-list for the Heimdall services)
5. systemd-journal-upload to Akasha `:19532`
6. Docker daemon config (`log-driver: journald`, `live-restore`, `userland-proxy: false`)
7. Repo cloned to `/opt/Homelab/`
8. Komodo Periphery installed via upstream `setup-periphery.py` and enabled in systemd
9. chrony NTP (UCG primary, public pool fallback)
10. unattended-upgrades

### 3. Verify

After `setup.sh` exits successfully:

```bash
# Static IP
ip -4 addr show | grep 192.168.10.4
# Should show the address on the uplink interface.

# Services running
systemctl is-active periphery.service nftables systemd-journal-upload chrony docker
# All should print `active`.

# Periphery listening on 8120 (localhost-bound; nftables enforces)
ss -tlnp | grep 8120
# Should show 127.0.0.1:8120 or [::]:8120 (the default).

# nftables ruleset loaded
sudo nft list ruleset | head -20
# Should show table inet heimdall_fw.

# DNS resolver no longer using stub
resolvectl status | head -10
# Should show DNS Servers from /etc/systemd/resolved.conf.d/no-stub.conf.

# Journal upload working (tail Akasha's journal-remote to confirm)
ssh truenas_admin@192.168.10.247 \
    'sudo journalctl --directory=/mnt/Media-Storage/Infra-Storage/journal-remote/ -n 10'
# Should show heimdall hostname in entries from approximately when journal-upload started.
```

## Recovery

If `setup.sh` fails partway, the per-step markers under `/var/lib/heimdall-setup/`
record which steps completed. Rerun the script — it will skip completed steps and
resume from the first incomplete step. If a step's underlying state has drifted
from what the marker claims, force re-run:

```bash
sudo bash /tmp/setup.sh --force 03_resolved
```

## Known gotchas (from actual install — May 2026)

These are documented so future reconstructions don't re-hit them:

- **`sudo git pull` creates files owned by root.** If you do `sudo git pull` in `/opt/Homelab/`, subsequent owner-as-non-root operations fail with "Permission denied". Fix: `sudo chown -R owner:owner /opt/Homelab` after any `sudo git`, or just use plain `git pull` (owner owns the repo per setup.sh step 7).

- **`nft flush ruleset` wipes Docker's NAT rules too.** If you re-apply nftables via `setup.sh --force 04_nftables`, Docker's iptables/nftables rules for container port mapping disappear. Symptom: `docker compose ps` shows no PORTS column on services that should be publishing ports. Fix: `sudo systemctl restart docker` to re-install the rules. The `live-restore: true` setting keeps containers running across the daemon restart.

- **`live-restore: true` + nftables flush + container restart = broken bridge networking.** Containers stay "running" but DNS resolution inside the bridge network fails ("Temporary failure in name resolution" on hostnames like `mongo`). Fix: `docker compose down && docker compose up -d` to fully tear down and recreate the bridge network. All persistent state is bind-mounted, so this is non-destructive.

- **`owner` not in `docker` group on first install.** setup.sh step 1 adds the user; if you ran an older setup.sh that didn't, fix manually: `sudo usermod -aG docker owner`. Takes effect on the next SSH session.

- **`forward` chain policy in nftables.conf must be `accept`, not `drop`.** Docker bridge networking (container-to-container traffic) transits the host's `forward` hook. The kernel sysctl `net.ipv4.ip_forward=0` (default) is what prevents Heimdall from acting as an L3 router; `policy accept` on the netfilter forward chain just allows Docker's bridge traffic to pass.

## Next

Proceed to [`phase-2-containers.md`](phase-2-containers.md).
