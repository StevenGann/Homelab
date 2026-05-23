# identity-overrides/

Per-node runtime metadata fragments. `flash-identity-usb.sh` reads the
file matching the target hostname and writes it (verbatim) to the
identity USB's `/identity.env`.

This directory is git-tracked so per-node values are reproducible across
USB stick reflashes. It deliberately does NOT contain secrets — secrets
live encrypted in `../secrets/common.yaml` (or per-node secrets files if
the cluster grows divergent enough to need them).

## Schema (version 2)

```
HYPERION_HOSTNAME=hyperion-alpha
HYPERION_NODE_IP=192.168.10.101
HYPERION_ROLE=worker
```

`HYPERION_ROLE` is a forward-compat slot — only `worker` exists today.

## Reading list

The flake's per-host `.nix` files under `../hosts/<hostname>.nix` set
**build-time** divergence (k3s labels/taints, Pi 5 overrides). This
directory's `.env` files set **runtime** divergence (hostname, IP).

Build-time = closure diverges; identity USB doesn't care.
Runtime    = closure is identical; identity USB provides the per-node values.

For now, the only runtime-varying values are `HYPERION_HOSTNAME` and
`HYPERION_NODE_IP`. If you find yourself adding more, ask whether it
should be build-time instead — that's the simpler path.
