# ADR-0002 — Containerized k3s control-plane networking limitation

**Status:** Accepted (with known debt) — 2026-06-01
**Supersedes/relates:** ADR-0001 (NixOS remote-flash); the Heimdall-home re-evaluation in `docs/todo.md`.

## Context

The Hyperion k3s **control plane runs as a Docker container on Heimdall**
(`Heimdall/k3s-control-plane/docker-compose.yml`), on Docker's default
**bridge** network. The container's IP is the docker-internal `172.19.0.2`,
not Heimdall's LAN IP `192.168.10.4` (Docker port-forwards `6443`, `8472/udp`,
etc.).

Kubernetes assumes every node has a **real, bidirectionally-reachable IP**:
the apiserver advertises it as the `kubernetes` service endpoint, and flannel
uses it as the VXLAN tunnel endpoint (VTEP). A bridge-networked container
violates that assumption. Symptoms observed while bootstrapping FluxCD/MetalLB
(2026-06-01):

1. **In-cluster API broken for worker pods.** The apiserver advertised
   `172.19.0.2:6443`; Pi pods hitting `10.43.0.1:443` timed out.
2. **Worker→control-plane-pod unreachable.** The control plane's flannel VTEP
   is `172.19.0.2`; Pis can send *to* it but it can't send *back* (return-path
   asymmetry). So any pod scheduled on the control-plane node is unreachable
   from the workers (broke cluster DNS, the Headlamp MetalLB VIP).
3. **apiserver→worker-pod return path** also fails for flannel traffic, breaking
   admission webhooks and aggregated APIs whose pods live on the Pis.

## Decision

**Keep the containerized control plane for now, with targeted workarounds, and
plan to relocate it.** Workarounds applied:

- `--advertise-address=192.168.10.4 --tls-san=192.168.10.4` on the k3s server
  (fixes #1 + workstation kubectl TLS).
- `--node-taint=node.homelab/control-plane-only=true:NoExecute` — no workloads
  on the control-plane node (fixes #2 for apps); apps pin to
  `nodeSelector topology.kubernetes.io/zone=hyperion`. Cluster DNS works because
  coredns runs on a Pi.
- The MetalLB controller is pinned **back onto** the control-plane node so the
  apiserver reaches its validating webhook locally (works around #3 for metallb).

## Consequences

- **Accepted casualty:** `metrics-server` / `kubectl top` is broken (apiserver↔
  Pi-pod return path; no clean workaround without relocation).
- k3s servicelb (klipper) still enabled → harmless `svclb-*` Pending pods.
- The workarounds are a pile of placement rules, fragile to extend.

**The durable fix is to relocate the control plane off the bridge-networked
container:** either `network_mode: host`, or (preferred) run it on its own host
or directly on the Heimdall host OS. Host-networking on Heimdall is **not** done
because k3s's kube-proxy/flannel iptables management would risk the co-tenant
Heimdall Docker services (Caddy/Technitium/Komodo). The operator has confirmed
the control plane will **move off Heimdall** as the next architectural step;
this ADR records why the interim workarounds exist so they can be removed at
relocation.
