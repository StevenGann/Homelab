# HANDOFF — Hyperion turnkey deploy (session handoff, 2026-05-29)

> **Why this file exists:** the operator is killing the agent instance running on
> the `192.168.0.x` workstation and restarting a fresh instance on a **laptop that
> is on the `192.168.10.0/24` (homelab) VLAN**. Local memory and session state do
> not transfer between machines — this committed doc is the handoff. Read it
> top-to-bottom, then resume at **"Resume here"** below.

---

## 1. The directive (what the operator actually wants)

Verbatim intent, captured 2026-05-29:

- **Hyperion has become a major problem; the operator no longer cares about IaC
  purity. They want Hyperion UP AND RUNNING.**
- Build a **single turnkey script** runnable from **any workstation on the homelab
  LAN**, as `sudo`, that:
  1. Deploys a fresh OS to the 10 Pi nodes (NixOS — see decision below).
  2. Deploys the k3s **server / control plane to Heimdall**.
  3. Does it with minimal operator effort.
- Invocation shape the operator suggested:
  `setup-hyperion-node.sh --name hyperion-alpha --ip 192.168.10.101` (or similar).
- Operator will **provide the IPs** (Heimdall + all 10 nodes) in any format we pick.
- **The operator has ORDERED SSH access to all systems** and offers passwordless
  sudo. We are expected to actually connect and operate, not just write scripts.
- We may add streamlining requirements. Stated assumption we can rely on:
  **every node will always boot a Debian-based distro with SSH enabled.**
- Operator told us to "deploy the team, fan out agents, operate autonomously."
  **DO NOT fan out a big agent swarm before ground-truthing the hardware** — the
  whole install method hinges on facts only a live node can confirm.

## 2. Decision already made (do not re-litigate)

The operator was asked to choose the node-OS strategy and **chose: "NixOS via
nixos-anywhere."** They picked it even though the option was framed as needing a
physical SD card per node. Interpretation: they want the real target OS (NixOS),
and will accept a one-time physical touch per node if it's truly irreducible.

**Our job is to make NixOS-on-the-nodes as turnkey-over-SSH as physically
possible, and be honest about any irreducible manual step.**

## 3. The core engineering constraint (the hard part)

NixOS on a Pi 5 has a **same-disk / chicken-and-egg** install problem: you cannot
repartition the NVMe you're booted from, so *something other than the running
Raspbian-on-NVMe* must drive the install. Two escape hatches:

- **kexec** — pivot the running Raspbian into a RAM installer. The repo's
  **ADR-0001 says kexec is broken on Pi 5** (`nixos-anywhere` #183 "missing
  /proc/kcore"; `nixos-raspberrypi` has no kexec support). **BUT** that conclusion
  was reached against the *nixos-raspberrypi* kernel, **not the Raspbian kernel
  that is actually running on the nodes today.** → **WORTH TESTING on real
  hardware.** If kexec works from Raspbian, the whole flow becomes zero-touch SSH.
- **Resident SD installer** — the branch's current design
  (`flash-node.sh` + `register-node-key.sh` + `installerSdImage`). Works, but needs
  a card inserted in each node once, and the EEPROM has to prefer SD for the first
  boot (the EEPROM change itself IS scriptable over SSH via `rpi-eeprom-config`).

**Worst case = one physical step ever: insert an SD card per node at assembly.**
Everything after (key registration, install, reboot, control-plane join, verify)
runs from the single script. Confirm which case applies by probing real hardware
before building.

## 4. Network reality (the blocker that ended the previous session)

The previous instance ran on a workstation at **`192.168.0.105/24`**. The homelab
is on **`192.168.10.0/24`**. Findings from that box:

| Target | L3 reachable | SSH | Cause |
|---|---|---|---|
| Heimdall `192.168.10.4` | ✅ ping via gw `192.168.0.1` | ❌ **timeout** | nftables accepts SSH only from `192.168.10.0/24`; `.0.x` source → `policy drop` |
| Nodes `192.168.10.101+` | ❌ **"No route to host"** | ❌ | Appear **powered off** (gateway can route the subnet — Heimdall proves it — but can't ARP the nodes) |

Heimdall's nftables (`Heimdall/hostconf/nftables.conf`) scopes SSH(22), k3s
API(6443), Komodo(9120), Technitium(5380), DNS(53) all to `192.168.10.0/24`. ICMP
is unrestricted (any source) — which is why ping worked but SSH didn't.

**This is why the operator is moving to the `.10` laptop.** From the `.10` VLAN,
all of Heimdall's firewall rules should permit the operator, and the nodes (if
powered on) should be directly reachable. **This also confirms the final
`setup-hyperion-node.sh` must be run from the `.10` subnet** — every firewall
assumption in Heimdall + k3s is built around that.

## 5. Heimdall access (verified-from-repo, not yet hardware-verified this session)

| | |
|---|---|
| SSH | `ssh owner@192.168.10.4` |
| OS | Ubuntu Server 26.04 LTS, hostname `heimdall` |
| User | `owner` — sudo (repo flow assumes passwordless), key-based auth (operator's workstation pubkey added at install) |
| Repo on host | `/opt/Homelab/` (owned by `owner`; do NOT `sudo git pull` — see phase-1 runbook gotchas) |
| Komodo UI | `http://192.168.10.4:9120` |
| Technitium UI | `http://192.168.10.4:5380` |
| Deploy script | `bash Heimdall/scripts/deploy.sh` (from workstation) |

Heimdall was set up May 2026 and **untouched since.** Komodo Core v2.2.0 runs there
on Ubuntu. The k3s control-plane stack is **coded but never hardware-validated.**

## 6. Repo state (facts, some diverge from docs/todo.md)

- Branch: **`feat/nixos-anywhere-remote-flash`**, **5 commits ahead of `main`, NOT
  merged.** This branch is the *second* NixOS design (nixos-anywhere remote-flash);
  it retired the earlier HYPERION-ID identity-USB model.
- `Hyperion/nixos/` scaffold is structurally complete (flake, disko, 10 host files,
  5 modules, installer, `flash-node.sh`, `register-node-key.sh`, runbooks, ADR-0001)
  but **not hardware-validated** (Phase 1 hard gate unmet).
- **`Hyperion/nixos/node-keys/` contains only README.md — NO node has actually been
  registered** under the new `register-node-key.sh` scheme.
- `Hyperion/.sops.yaml` has a leftover node pubkey (`age1qh63…`) from the *old*
  identity-USB commit, not from the new flow. Treat as stale.
- **`docs/todo.md` is STALE** — it still describes the retired identity-USB flow
  (`flash-identity-usb.sh`, `apply-identity.service`, "flash alpha's identity USB").
  The authoritative current flow is
  `Hyperion/docs/runbooks/remote-flash-a-node.md`.
- k3s control plane: `Heimdall/k3s-control-plane/` pins `rancher/k3s:v1.34.5-k3s1`,
  join token minted (commit `0c387e4`), encrypted to both sides per CLAUDE.md.
  Never started on real hardware (unverified).
- k3s version alignment: server `v1.34.5-k3s1` ↔ nixpkgs 25.11 workers (same minor).

## 7. Open questions the operator still needs to answer

1. **Are the Hyperion nodes powered on?** They looked offline from the `.0.x` box.
   Re-test from the `.10` laptop first thing.
2. **Is the `.0` / `.10` split intentional VLAN segmentation on the UCG?** (Affects
   nothing if we always deploy from `.10`, but good to know.)
3. **Inventory** — still owed: Heimdall IP + all 10 node IPs + names. Proposed
   format (also the format the final script will consume), to live at
   `Hyperion/inventory.yaml`:
   ```yaml
   heimdall:
     ip: 192.168.10.4
     ssh_user: owner
   nodes:
     - { name: hyperion-alpha, ip: 192.168.10.101 }
     - { name: hyperion-beta,  ip: 192.168.10.102 }
     # ... through hyperion-kappa (.110)
   ```
4. **Node SSH user + auth** — UNKNOWN. Raspbian default `pi`? something else? Which
   private key, or is it in `~/.ssh/config` / agent on the laptop?
5. **sudo on nodes** — passwordless already, or do we lay down a NOPASSWD drop-in on
   first connect?

## 8. RESUME HERE (first actions for the laptop instance, on the `.10` VLAN)

Do these in order. **Ground-truth before building. Do not fan out agents yet.**

1. **Confirm operator access from the laptop:**
   ```bash
   ssh -o ConnectTimeout=5 owner@192.168.10.4 'hostnamectl; sudo -n true && echo SUDO_OK'
   ```
2. **Re-test node reachability + power** (were offline from `.0.x`):
   ```bash
   for n in 101 102 103 104 105 106 107 108 109 110; do
     ping -c1 -W2 192.168.10.$n >/dev/null 2>&1 && echo ".$n UP" || echo ".$n down"
   done
   ```
   If nodes are down → operator must power them on (step zero).
3. **Probe `hyperion-alpha` (192.168.10.101)** over SSH to pick the install method:
   - boot device + disk layout (`lsblk`, `findmnt /`, is root on NVMe?)
   - EEPROM config (`rpi-eeprom-config`)
   - **kexec feasibility** (does `kexec` exist / is `/proc/kcore` present / kernel
     `CONFIG_KEXEC`? a cautious test could tell us if zero-touch is possible)
   - internet reachability to `nixos-raspberrypi.cachix.org` + `cache.nixos.org`
   - SD card slot status / whether a card is present
4. **Probe Heimdall:** is anything listening on `:6443`? Is the k3s control-plane
   container running, or only Komodo? `ssh owner@192.168.10.4 'docker ps; ss -tlnp | grep 6443'`
5. **Decide the install method** (zero-touch kexec vs. one-card SD installer) from
   the probe results, and tell the operator the irreducible manual step (if any).
6. **THEN** build, ideally fanning out in parallel:
   - node installer logic (wrap/validate `flash-node.sh` + `register-node-key.sh`)
   - Heimdall control-plane bring-up (`Heimdall/scripts/deploy.sh` path)
   - the single `setup-hyperion-node.sh` orchestrator + `inventory.yaml` parser
   - a verification harness (node Ready in `kubectl get nodes`, etc.)
7. **Validate end-to-end on alpha for real**, then roll the remaining 9.

## 9. Things to be careful about

- Don't `sudo git pull` in `/opt/Homelab/` on Heimdall (creates root-owned files;
  see `Heimdall/docs/runbooks/phase-1-host.md` gotchas).
- Heimdall nftables `policy drop` on input: re-applying it can wipe Docker's NAT
  rules → `sudo systemctl restart docker`. Same runbook.
- We are on a feature branch, not main — fine to commit work here.
- The operator is fatigued with this project. Bias to action and reliability over
  IaC elegance. Be honest about manual steps; don't over-promise "turnkey."
