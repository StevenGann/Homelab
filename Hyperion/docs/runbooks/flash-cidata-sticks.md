# Runbook: Flash cidata USB Sticks

Each Hyperion node reads its identity from a USB stick with the volume label
`cidata`. cloud-init reads two files from it on first boot:

| File | Purpose |
|------|---------|
| `meta-data` | Sets `instance-id` and `local-hostname` for this specific node |
| `user-data` | Shared config: SSH key, k3s token, join script, storage setup |

`user-data` is stored SOPS-encrypted in the repo. The flash script decrypts it
once in memory and writes the plaintext to each stick — it is never written to
disk on your workstation unencrypted.

---

## Prerequisites

```bash
sudo apt-get install -y dosfstools
```

Ensure your age key is present:
```bash
ls ~/.config/sops/age/keys.txt
```

---

## Flash All 10 Sticks

```bash
cd ~/GitHub/Homelab/Hyperion
./cloud-init/flash-cidata-sticks.sh
```

The script will:
1. Decrypt `user-data.template.yaml` once using your age key
2. Walk through each node (alpha → kappa) one at a time
3. Prompt you to insert a USB stick
4. Auto-detect the newly inserted device
5. Ask for confirmation before formatting
6. Format as FAT32 with label `cidata`
7. Write `meta-data` (node-specific) and `user-data` (shared)
8. Unmount and prompt you to label and remove the stick

## Flash a Single Stick (e.g. replacement node)

```bash
./cloud-init/flash-cidata-sticks.sh hyperion-gamma
# or just the Greek name:
./cloud-init/flash-cidata-sticks.sh gamma
```

---

## After Flashing

- Label each stick with the node name (a piece of tape works fine)
- Insert the correctly labelled stick into the corresponding Pi **before** powering it on
- The stick must remain inserted during first boot so cloud-init can read it
- After provisioning is complete the stick can be removed and kept as a spare

---

## Node Replacement

If a node dies:
1. Move the dead node's cidata stick to the replacement Pi
2. Update the MAC address in the UCG DHCP reservation for that hostname
3. Boot — the replacement gets the same hostname, IP, and rejoins the cluster

If the cidata stick is also lost, re-flash a new one:
```bash
./cloud-init/flash-cidata-sticks.sh hyperion-eta
```
