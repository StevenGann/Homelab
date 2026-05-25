# Heimdall — Planning

> **Status:** scaffolding. Decisions not yet locked in. This document is a working draft for the conversation with the standing agent team (see [`TEAM.md`](../../TEAM.md) and [`PIPELINES.md`](../../PIPELINES.md)).

## Goal

Stand up Heimdall as the Homelab's edge-services host: reverse proxy, load balancer, and DNS. Hardware is in hand (Ubuntu Server 26.04 LTS, clean install) — the task is to (1) pick a tech stack, (2) define how it slots into the existing network and k3s cluster, (3) produce IaC under `Heimdall/` that brings the host from clean-install to running state without manual steps beyond what `README.md` documents.

See [`Heimdall/README.md`](../../Heimdall/README.md) for hardware and NIC assignments.

## Roles to provide

1. **Reverse proxy** — TLS termination, HTTP(S) routing into the cluster, ACME for cert issuance.
2. **Load balancer** — north–south traffic distribution. Open question: relationship to MetalLB (which today owns `192.168.10.10–.99`).
3. **DNS** — at minimum, authoritative records for the Homelab. Recursive resolution for LAN clients is a separate decision.

## Candidate tech stacks

To be evaluated by the team — not yet ranked. Listed for the planning conversation to attack.

### Reverse proxy / LB
- Traefik (k8s-native, IngressRoute CRDs, runs well as a Docker stack or on the host)
- Caddy (simplest config, automatic ACME, weaker LB story)
- NGINX (already used on Akasha for the image server; familiar)
- HAProxy (strongest LB feature set, weakest UX)
- Envoy (xDS power, heavy to operate by hand)

### DNS
- Unbound (recursive) + NSD (authoritative) — classic split
- PowerDNS (auth + recursor as separate daemons; SQL/LMDB backends)
- CoreDNS (k8s-flavored, plugin-driven, can do both)
- BIND9 (battle-tested, syntax-heavy)
- Pi-hole / AdGuard Home (recursive + ad-blocking; less rigorous as authoritative)

### IaC mechanism for Heimdall itself
- Ansible playbook under `Heimdall/ansible/` (matches Hyperion post-imaging style)
- Docker Compose stack (matches Akasha style — services live in containers, host stays minimal)
- A mix: Ansible to set up the host (netplan, base packages, container runtime), Compose for the services
- Packer image (overkill for a single host; pattern only makes sense at >1 instance)

## Open questions for the team

Carry over from [`Heimdall/docs/network-layout.md`](../../Heimdall/docs/network-layout.md):

- IP allocation per NIC and whether subnets stay flat or split per fabric.
- Whether Heimdall routes between fabrics or the UCG continues to.
- DHCP authority: UCG keeps it, or Heimdall absorbs it alongside DNS.
- Reverse-proxy vs. MetalLB: which is canonical entry point for which class of service.
- Reserve-port use: bonded uplinks, future fabrics, or OOB management.

Additional planning-level questions:

- **Failure domain.** Heimdall is a single box. Acceptable as SPOF for the homelab, or do we plan keepalived/anycast/etc. for HA from day one?
- **State.** DNS zones, proxy config, ACME accounts — version-controlled in this repo (SOPS for secrets) or kept on disk only?
- **Observability.** Does Heimdall stream to `journal-remote` on Akasha (consistent with Hyperion), or run its own logging?
- **Hardening.** Ubuntu 26.04 baseline plus what? unattended-upgrades, ufw/nftables, fail2ban, SSH key-only?

## Decisions log

Append decisions here as they're made. Format:

```
- YYYY-MM-DD — <decision> — <one-line rationale> — <links to discussion / PRs>
```

- 2026-05-17 — **Raspberry Pi Expert is excluded from the Heimdall team.** Heimdall is x86 and the Pi specialty does not load-bear here. Stage 1 of the first DEVELOPMENT pipeline run used 3 specialists (Linux, Old Man, IaC/DevOps) plus the two adversaries; the Pi Expert's already-completed Stage 1 proposal was archived under `docs/pipeline-runs/20260517T183851Z-dev-heimdall-tech-stack/01-proposals/_excluded/`. Future Heimdall pipeline runs should mirror this composition.

- 2026-05-17 — **Heimdall tech stack approved (DEVELOPMENT pipeline `20260517T183851Z-dev-heimdall-tech-stack`, PASS on iter-1, 5 YAE / 0 NAY).** v1 stack: **AdGuard Home + Caddy v2.11.3 with the `caddy-l4` plugin + Dockge**, three containers on Ubuntu Server 26.04 LTS via Docker CE upstream repo. **SUPERSEDED — see the 2026-05-17 (finalize) entry below.** Historical reference only.

- 2026-05-17 — **Heimdall tech stack finalized (DEVELOPMENT pipeline `20260517T213331Z-dev-heimdall-finalize`, PASS on iter-1, 5 YAE / 0 NAY).** Three decisions from the prior run were overturned: **AdGuard Home → Technitium DNS Server v15** (authoritative `.lab` zone, CNAME-cloaking detection, clustering-ready for a future Akasha secondary); **Dockge → Komodo v2.2.0** (Core+Periphery; per-container exec terminal in UI; Periphery runs as a host systemd binary, NOT a container); **MetalLB removed entirely from the cluster** (Caddy fans out to per-Pi-node NodePorts with active health checks; `--disable=servicelb --disable=traefik` on the k3s server). Four containers + one host systemd binary = five things to manage. Three operational phases: Phase 1 (host setup), Phase 2 (containers stand up with end-to-end `komodo.lab` self-test), Phase 3 (ongoing route + zone additions). Authoritative design: `docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md`. Implementation punch list (10 items, 3 MAJOR script-body bugs): `docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/FINAL.md`.

- 2026-05-17 — **Action-tagged deadline: Technitium-secondary on Akasha.** At Heimdall Phase 2 completion, an entry must be added to `docs/todo.md` with target date = Phase-2-completion-date + 6 months, with **binary outcome only**: (a) revert Heimdall to AdGuard Home, or (b) deploy the Akasha secondary in that month's pipeline run. No "defer further" option. Mechanism: the `docs/todo.md` entry itself. The Technitium swap's named justification (DNS HA via clustering) must arrive within 6 months or be retracted.

- 2026-05-17 — **Heimdall static IP changed from `.240` to `.4` during implementation.** Reason: the approved plan (`docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md`) picked `.240` on the framing of "high static, mirrors Akasha `.247`" convention. The convention was unsound — the UCG's DHCP dynamic pool runs `192.168.10.129–.254`, so both `.240` and Akasha's `.247` are inside the dynamic range and depend on UCG's ARP-probe-skip behavior to remain stable. `.4` is fully outside the DHCP pool (the safe static range is `.2–.128`), needs no UCG cooperation, and matches the Linux Expert's iter-1 Stage-1 proposal. The pipeline-run FINAL.md retains `.240` as the historical record of what the team approved; the operational files under `Heimdall/` (netplan, runbooks, seed-zones script, etc.) use `.4` as the implemented value. Sweep was a one-pass `sed` across 9 files; ~32 references updated. The netplan match is also tightened from `match: { name: "en*" }` to `match: { macaddress: ... }` per the implementing engineer (more robust to kernel/firmware NIC-naming shifts).

## Next steps

1. Team review of candidate stacks (specialists propose, adversaries attack — per `PIPELINES.md`).
2. Lock the network layout (IPs, VLANs, routes).
3. Pick the IaC mechanism, scaffold under `Heimdall/`.
4. Write the bring-up runbook in `Heimdall/docs/runbooks/`.
