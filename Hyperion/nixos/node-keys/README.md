# node-keys/

Per-node secret bundles for the nixos-anywhere remote-flash flow.

Each `hyperion-<name>.tar.age` is a tar of the exact on-target layout —

```
./var/lib/sops-nix/key.txt          # per-node sops age private key
./etc/ssh/ssh_host_ed25519_key      # stable SSH host key (no known_hosts churn)
./etc/ssh/ssh_host_ed25519_key.pub
```

— **age-encrypted to the operator's key only**. These files are committed: an
attacker without the operator age key cannot decrypt them, and they are the
durable source of truth for re-flashing a node with the same identity.

## Lifecycle

- Created/registered by `../../register-node-key.sh <hostname>`, which also
  adds the node's age **public** key to `../../.sops.yaml` and re-encrypts
  `../secrets/common.yaml`.
- Consumed by `../../flash-node.sh <ip> <hostname>`, which decrypts the bundle
  into a temp `--extra-files` tree and passes it to nixos-anywhere.
- Rotate with `../../register-node-key.sh <hostname> --rotate` (then re-flash;
  the node's old key stops working).

Losing a bundle means you must `--rotate` (new key) and re-flash that node.

See `../../docs/runbooks/remote-flash-a-node.md` and
`../../../docs/design/adr-0001-nixos-anywhere-remote-flash.md`.
