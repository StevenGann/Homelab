# Thoth — GPU compute host IaC Plan

> **Status:** Plan / not yet built — 2026-06-02. Thoth is a fresh **Ubuntu Server
> 26.04** install at **`192.168.10.144`** with **2× RTX 6000 Ada** GPUs. It is
> reachable on the LAN (ping ~11 ms) but **SSH key access is not yet established**
> (`Permission denied (publickey,password)`) — that is step 0.
>
> Goal: bring Thoth under IaC **consistent with Heimdall's container pattern**
> (`docker compose` + SOPS-secrets-shipped-by-`deploy.sh` + a host-bootstrap
> `setup.sh`), with **CUDA GPU access for containers as a first-class, critical
> requirement**. First three workloads: **Ollama**, **Tdarr worker**, **Minecraft
> Pterodactyl Wings**.
>
> Per the repo convention (CLAUDE.md), Thoth gets its own top-level `Thoth/`
> directory. This plan mirrors `Heimdall/`.

---

## 0. Access (blocker — do first)

I cannot reach Thoth over SSH yet; the workstation key isn't authorized on the
fresh install. Establish it before anything else:

```bash
# On the workstation (replace <user> with the install's admin user):
ssh-copy-id <user>@192.168.10.144
# or append ~/.ssh/id_ed25519.pub to /home/<user>/.ssh/authorized_keys on Thoth.
```

Then NOPASSWD sudo for the deploy user (mirrors Heimdall), so `deploy.sh`/`setup.sh`
can run unattended. **Operator input needed: the admin username on Thoth.**

---

## 1. Host overview & GPU baseline

| | |
|---|---|
| Host | Thoth, `192.168.10.144`, Ubuntu Server 26.04 |
| GPUs | 2× NVIDIA RTX 6000 Ada (48 GB each; Ada NVENC/NVDEC, unlimited encode sessions) |
| Network | 1 GbE LAN (single VLAN); 10 GbE to the HPC switch (bulk path to Akasha) per the redesign |
| Role | GPU compute: LLM inference (Ollama), hardware transcode (Tdarr worker), game servers (Wings) |

**The GPU stack is the load-bearing part.** Three layers, all required:

1. **Host NVIDIA driver** — the proprietary driver for Ada (no host CUDA toolkit
   needed; containers carry their own CUDA userspace). On 26.04, install via
   `ubuntu-drivers install` or NVIDIA's CUDA apt repo. **Verify a 26.04-supported
   driver branch exists** (26.04 is brand new — this is the one thing to confirm on
   the box before committing; fallback is the `.run` installer or the CUDA repo
   `cuda-drivers` package).
2. **NVIDIA Container Toolkit** — add NVIDIA's repo, `apt install
   nvidia-container-toolkit`, then `sudo nvidia-ctk runtime configure
   --runtime=docker && sudo systemctl restart docker`. This wires the `nvidia`
   runtime into `/etc/docker/daemon.json`.
3. **Per-container GPU request** in compose (modern syntax — no `runtime: nvidia`):
   ```yaml
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             device_ids: ["0"]        # or count: all
             capabilities: [gpu]      # Tdarr adds "video" for NVENC/NVDEC
   ```

**Host smoke test (gate before any workload):**
```bash
sudo docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
# must list both RTX 6000 Ada cards.
```

### GPU allocation across the three workloads

NVENC/NVDEC (Tdarr) and CUDA cores (Ollama) are separate engines, so the two can
**share both GPUs** without much contention; Wings/Minecraft needs no GPU.
**DECIDED (2026-06-02): both workloads see BOTH GPUs** (`count: all`); monitor with
`nvidia-smi` and pin via `device_ids` only if they ever contend.

---

## 2. IaC layout — `Thoth/` (mirrors `Heimdall/`)

```
Thoth/
  README.md
  docker-compose.yml            # ollama + tdarr-node + wings (one project)
  .sops.yaml                    # same single homelab age key as Heimdall/Hyperion
  scripts/
    setup.sh                    # host bootstrap (run ON Thoth): docker, NVIDIA driver,
                                #   container toolkit, runtime config, nftables, GPU smoke test
    deploy.sh                   # workstation-side: SOPS-decrypt+ship secrets via SSH, compose up
    generate-secrets.sh         # mint machine secrets into secrets/*.sops.*
  hostconf/
    docker-daemon.json          # nvidia runtime + journald logging (mirror Heimdall)
    nftables.conf               # firewall (LAN-scoped service ports + game ports)
  secrets/
    env.sops.env                # compose env (Wings token, etc.) — SOPS-encrypted
```

Same operating model as Heimdall: secrets live SOPS-encrypted in git, `deploy.sh`
decrypts on the workstation and ships cleartext to `/opt/Homelab/Thoth/.env` (mode
600) over SSH, then `docker compose up -d` on the host. State under a single root
`/opt/Homelab/Thoth/` for rsync-one-root portability.

---

## 3. Workloads

### 3a. Ollama (LLM inference — GPU)

- Image `ollama/ollama`; port **11434**; models volume `/opt/Homelab/Thoth/ollama`
  (models are many GB — ensure it lives on a large disk).
- GPU via the device reservation (capabilities `[gpu]`).
- **Exposure — DECIDED: Caddy-fronted `ollama.lab`.** Publish `11434` on the LAN,
  add a Heimdall Caddy block `ollama.lab { reverse_proxy 192.168.10.144:11434 }`
  (+ DNS `ollama.lab → 192.168.10.4`), optionally with basic-auth. Ollama gotcha:
  set `OLLAMA_HOST=0.0.0.0` in the container and `OLLAMA_ORIGINS` to allow the proxy
  host (Ollama does DNS-rebind/origin checks — see [[project_reverse_proxy_localhost_guard]]).
  Internal only; not on the Cloudflare tunnel.

### 3b. Tdarr worker/node (hardware transcode — GPU + NFS)

- Image `ghcr.io/haveagitgat/tdarr_node`; **internalNode=false**, connects OUT to
  the Tdarr **server on Hyperion** at `http://192.168.10.62:8266`
  (`serverURL`), nodeName e.g. `thoth-gpu`.
- GPU with capabilities **`[gpu, video]`** (NVENC/NVDEC) — this is the whole point
  of a GPU worker.
- **Storage dependency (must resolve first):** the node needs the **same paths as
  the server** — the media library + a **shared transcode cache**. Today the Tdarr
  server's cache is an `emptyDir` (`Hyperion/k8s/apps/media/20-extras/tdarr/
  deployment.yaml` has a TODO: "must become a SHARED NFS export when Thoth worker
  is added"). So adding Thoth requires: (1) an Akasha NFS export for the cache,
  (2) the server pod remounts it, (3) Thoth NFS-mounts both the cache and the media
  library. **Operator input: Akasha exports (media `/data` + shared `/temp`).** Use
  the 10 GbE path to Akasha for this traffic.

### 3c. Pterodactyl Wings (Minecraft — no GPU)

- Image `ghcr.io/pterodactyl/wings`; runs game-server containers via the host
  **docker socket** (`/var/run/docker.sock`) + `/var/lib/pterodactyl`.
- Connects to the **panel on Hyperion** (`192.168.10.69`). Flow: in the panel UI,
  create a **Node** for Thoth → panel emits a config/token → that becomes Wings'
  `config.yml`/auto-deploy token (a **secret** → SOPS).
- Ports: Wings daemon **8080** (or 443 + a cert), SFTP **2022**, and **allocated
  game ports** (Minecraft **25565/tcp**). These game ports are also what the UCG
  forwards for public play (ties into the `mc.stevengann.com` DDNS+port-forward
  from the SSO/public-access work).
- **Operator input: create the Thoth node in the panel** to get the token (UI step,
  not codifiable here).

---

## 4. Networking, DNS, secrets

- **DNS:** add `thoth.lab → 192.168.10.144` (and optionally `ollama.lab`) to
  `Heimdall/scripts/seed-zones.sh`.
- **Ports (LAN):** 11434 (Ollama), 8080+2022 (Wings) + game ports; Tdarr node is
  outbound-only. `hostconf/nftables.conf` scopes service ports to the LAN; game
  ports open as needed.
- **Secrets (SOPS, same age key):** Wings node token/config; any Ollama/API keys if
  fronted with auth. Tdarr node needs no secret (just the server URL). `deploy.sh`
  ships them like Heimdall.

---

## 5. Phased rollout

1. **Access + host bootstrap** — key/sudo, then `setup.sh`: docker + NVIDIA driver +
   container toolkit + runtime config; pass the `--gpus all` smoke test. (Gate.)
2. **Ollama** — simplest GPU win; validate a model runs on-GPU (`nvidia-smi` shows
   the process). Confirms the whole GPU-in-container path end to end.
3. **Tdarr worker** — only after the Akasha shared-cache export exists and the
   server remounts it; then the node registers and takes GPU transcode jobs.
4. **Wings** — create the panel node, ship the token, bring up Wings, spin a
   Minecraft server, wire the game port-forward.

Each phase is independently useful; phase 2 proves the GPU stack.

---

## 6. Open decisions / operator inputs

- **Admin username** on Thoth (for key + sudo). ← STILL BLOCKING step 0.
- **Driver install path on 26.04** — confirm a supported driver branch on the box.
- ~~GPU allocation~~ — DECIDED: both GPUs shared (§1).
- **Akasha NFS exports** for the Tdarr shared cache + media library (blocks 3b).
- **Pterodactyl panel node** creation to mint the Wings token (blocks 3c).
- ~~Ollama exposure~~ — DECIDED: Caddy-fronted `ollama.lab` (§3a).
- **Jellyfin-on-Thoth?** the redesign floats Thoth as a future Jellyfin host — out
  of scope here, but GPU transcode for Jellyfin would reuse this same stack.

---

## 7. References

- Heimdall pattern to mirror: `Heimdall/{docker-compose.yml,scripts/setup.sh,
  scripts/deploy.sh,hostconf/,secrets/,.sops.yaml}`.
- Thoth role + topology: `docs/design/homelab-redesign.md` (2× RTX 6000 Ada, 10 GbE).
- Tdarr server (worker connects here): `Hyperion/k8s/apps/media/20-extras/tdarr/`
  (`.62:8266`; the emptyDir→NFS TODO).
- NVIDIA Container Toolkit install + compose GPU syntax:
  <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>,
  <https://docs.docker.com/compose/how-tos/gpu-support/>.
