# Disaster Recovery — rebuild order & the secret-recovery bootstrap

Companion to [`docs/dr-readiness-2026-07-04.md`](../dr-readiness-2026-07-04.md)
(the repo-vs-live audit). This runbook covers the **load-bearing prerequisite**
the DR report flagged as CRITICAL (C2): a from-scratch Flux bootstrap cannot
decrypt any SOPS secret until the `sops-age` key is recreated. Do these steps
**before** expecting Flux to reconcile.

## 0. The single recovery root — back this up off-site

**`~/.config/sops/age/keys.txt`** (the operator age key) is the sole key that
can decrypt every `*.sops.yaml` in this repo *and* the per-node
`Hyperion/nixos/node-keys/*.tar.age`. It is intentionally **never** in git.
If it is lost, every encrypted secret and the NixOS rebuild are unrecoverable.

> **Store a copy off-site** (password manager + offline media). Public half is
> `age1u8tfm7scg35csrnam9ntnppne5728593yw7fk3p9sz7ecl06dpgs958ncm` — it must
> stay listed in `Hyperion/.sops.yaml`.

## 1. Rebuild order after catastrophic loss

1. **Akasha (TrueNAS)** — pool/datasets/NFS exports first; the cluster's NFS PVs
   bind to concrete paths. (Config-as-code gap — see DR report H10.)
2. **Heimdall** — `bash Heimdall/scripts/deploy.sh` brings up the edge stack
   (Caddy, Technitium, Pi-hole, Komodo, k3s control plane). Then the DNS
   recursion step below, or the whole homelab has no external DNS.
3. **Hyperion nodes** — flash + join per `Hyperion/docs/runbooks/turnkey-node-setup.md`.
4. **Flux `sops-age` key** (section 2) — **before** the app reconcile.
5. **Flux bootstrap** — `kubectl apply -k Hyperion/k8s/flux-system`; it pulls
   the public repo and reconciles everything else.

## 2. Recreate the Flux `sops-age` secret (or nothing decrypts)

Every `k8s/**/*.sops.yaml` is encrypted to the operator key **and** a dedicated
in-cluster Flux age key whose private half lives only in the
`flux-system/sops-age` Secret. A fresh cluster has neither. Two options:

**A. Restore the original key** (if you backed it up) — preserves all existing
ciphertext unchanged:

```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=/path/to/backup/flux-age.txt
```

**B. Mint a new key** — then you MUST re-encrypt every secret to it:

```bash
age-keygen -o flux-age.txt                       # note the public key it prints
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=flux-age.txt
# swap the new pubkey into Hyperion/.sops.yaml (replace age1wjvfq...), then:
find Hyperion/k8s -name '*.sops.yaml' -exec \
  sops --config Hyperion/.sops.yaml updatekeys -y {} \;
git commit -am 'chore(sops): rotate flux age recipient' && git push
```

> The Kustomizations that consume secrets already carry
> `decryption: { provider: sops, secretRef: { name: sops-age } }`. **Any new app
> with a `*.sops.yaml` MUST add that block** — otherwise Flux applies the secret
> un-decrypted (raw `ENC[...]` as the value) and the app fails. `.sops.yaml`
> files must keep `encrypted_regex: ^(data|stringData)$` (in `.sops.yaml`), or
> Flux's decryptor rejects them with "does not match sops' data format".

## 3. Restore external DNS (Technitium recursion)

Technitium is authoritative for `.lab` but ships with `recursion: Deny` /
`forwarders: None`, so with Pi-hole pointed at it as sole upstream the whole
homelab loses external DNS. Re-apply the forwarder config (also seeded by
`Heimdall/scripts/seed-zones.sh`):

```bash
# on Heimdall; TOKEN from the Technitium admin login (see seed-zones.sh get_token)
curl -fsS "http://127.0.0.1:5380/api/settings/set?token=$TOKEN" \
  -G --data-urlencode "recursion=AllowOnlyForPrivateNetworks" \
     --data-urlencode "forwarders=1.1.1.1, 8.8.8.8" \
     --data-urlencode "forwarderProtocol=Udp"
```
