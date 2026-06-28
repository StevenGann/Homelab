# Cluster recovery after a full-rack power cycle

Operator-facing runbook for bringing the k3s cluster back after the whole rack
loses or cycles power. First exercised 2026-06-27 (first full-rack power cycle).

**TL;DR:** the cluster mostly self-heals, but a leftover **cordon** on the
Hyperion workers will silently block recovery. After any power cycle, check for
`SchedulingDisabled` nodes and `uncordon` them before assuming a deeper problem.

## What recovers on its own (and why)

Nothing here needs operator action — it's documented so you know what to expect:

- **Control plane** — Heimdall's `docker.service` is `enabled` on boot, and the
  `k3s-control-plane-k3s-server-1` container is `restart=unless-stopped`. So when
  Heimdall powers up, Docker starts and the control plane comes back automatically.
- **Workloads** — every app is a Deployment / StatefulSet / DaemonSet, so the
  controllers recreate pods once the control plane is reachable.
- **Pods on a returning worker** — a pod already bound to a node
  (`spec.nodeName` set) has its containers restarted by that node's returning
  kubelet **regardless of cordon**. This is why most pods come back up even when
  the nodes are cordoned (see below) — and why "lots of containers are down"
  right after power-on is usually just things still starting/mounting NFS.

## The trap: a leftover cordon blocks self-healing

Cordon (`kubectl cordon` / the implicit cordon from `kubectl drain`) sets
`spec.unschedulable: true` on the node. That flag **lives in the datastore and
survives reboots.** Cordon does *not* evict running pods and does *not* stop a
returning kubelet from restarting pods already bound to its node — it only stops
the **scheduler** from placing **new or rescheduled** pods. The result is a
cluster that looks ~healthy (most pods Running) but **cannot self-heal**: any pod
that needs fresh placement sits `Pending` forever.

On 2026-06-27 all 10 Hyperion workers came up `Ready,SchedulingDisabled` — most
likely a `kubectl drain` used to prep the rack with no matching `uncordon`
afterward.

> Note: the `hyperion.lab/memory-tier` taints on `hyperion-beta` and
> `hyperion-gamma` are **intentional** and unrelated to the cordon. The cordon
> shows up as the `node.kubernetes.io/unschedulable` taint and the
> `SchedulingDisabled` status.

## Recovery procedure

All `kubectl` runs inside the control-plane container on Heimdall (there is no
host `kubectl`); see `Heimdall/k3s-control-plane/README.md`.

```bash
# From the workstation. Define a helper for brevity:
kc() { ssh owner@192.168.10.4 docker exec k3s-control-plane-k3s-server-1 kubectl "$@"; }

# 1. Are all nodes back and Ready?
kc get nodes -o wide

# 2. Look for the trap: any node showing SchedulingDisabled?
kc get nodes      # STATUS column reads "Ready,SchedulingDisabled" if cordoned

# 3. Uncordon every worker that is cordoned (safe + idempotent):
kc uncordon hyperion-alpha hyperion-beta hyperion-gamma hyperion-delta \
            hyperion-epsilon hyperion-zeta hyperion-eta hyperion-theta \
            hyperion-iota hyperion-kappa

# 4. Confirm the cluster settles — expect only Running + Completed (finished Jobs):
kc get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
kc get pods -A --field-selector=status.phase!=Running   # ignore Completed Jobs

# 5. Spot-check workload availability:
kc get deploy,sts,ds -A | awk 'NR==1 || $0 !~ /([0-9]+)\/\1/'
```

If nodes are `NotReady` rather than cordoned, that's a different failure — start
with the containerized-control-plane networking caveat
(`docs/design/adr-0002-containerized-control-plane-networking.md`) and the
Heimdall Docker-NAT hazard (a global `nft -f` flush nukes Docker's DNAT →
`systemctl restart docker` to recover).

## Prevention

If you ever `drain`/`cordon` nodes to gracefully prep a shutdown, **pair it with
an `uncordon`** as the final step of bring-up. There is no boot-time automation
that clears the flag — it is operator-owned state.
