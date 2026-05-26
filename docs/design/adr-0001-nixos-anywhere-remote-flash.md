# ADR-0001 — NixOS install via nixos-anywhere from a resident SD installer

- **Status:** Accepted (2026-05-25)
- **Context area:** Hyperion NixOS first-install / re-flash
- **Supersedes:** the dd-to-NVMe-on-workstation + HYPERION-ID identity-USB flow
  (see `Hyperion/nixos/installer/installer.nix` history and the retired
  `flash-identity-usb.sh`).

## Context

The goal: fully remote node provisioning — operator assembles hardware and
assigns an IP; everything else (install OS onto NVMe, place secrets, reboot)
happens over the network. The prior NixOS scaffold required physically
dd-ing an image to the NVMe via a USB adapter and inserting a per-node
identity USB. The Debian path's network reflash was never made reliable
("the SSDs aren't getting reflashed").

`nixos-anywhere` is the natural tool for remote, closure-based installs, and
it injects secrets at install via `--extra-files`. The question was how to
make it work on the Raspberry Pi 5.

## Decision

1. **Boot a live NixOS installer from a resident microSD**, not kexec.
   `nixos-anywhere`'s default bootstrap kexecs a running non-NixOS host into a
   RAM installer. **kexec is broken on the Pi** — `nixos-anywhere` issue #183
   ("kexec fails on Raspberry Pi OS: missing /proc/kcore") and
   `nixos-raspberrypi` explicitly does not support kexec. The nixos-anywhere
   docs say ARM targets must "boot from a NixOS installer image." So each node
   carries an identical SD installer (`packages.installerSdImage`, built via
   `nixos-raspberrypi.lib.nixosInstaller`).

2. **EEPROM `BOOT_ORDER=0xf16`** (NVMe → SD → loop). An installed NVMe wins; a
   blank NVMe falls through to the SD installer. The SD stays resident and
   ignored in normal operation, and is the re-flash/recovery path.

3. **`--build-on-remote`.** The per-host aarch64 closure is built on the node
   (substituted from `nixos-raspberrypi.cachix.org`), so the x86 workstation
   never cross-compiles. The workstation only evaluates the flake and
   orchestrates over SSH.

4. **`--phases disko,install,reboot`** — skip kexec; disko partitions
   `/dev/nvme0n1` from the host closure.

5. **Retire the HYPERION-ID USB.** Identity (hostname, k3s labels/taints) lives
   in `hosts/<hostname>.nix`; node IP is the UCG DHCP reservation. The per-node
   sops age key and SSH host keys are injected via `--extra-files` to
   `/var/lib/sops-nix/key.txt` and `/etc/ssh/`. Keys are generated
   workstation-side by `register-node-key.sh`, stored age-encrypted to the
   operator in `nixos/node-keys/<hostname>.tar.age` (committed; the durable
   source of truth across re-flashes), and the pubkey registered in
   `.sops.yaml`.

## Consequences

**Positive**
- Fully remote after assembly; no USB-to-NVMe adapter, no NVMe handling, no
  identity USB.
- One install mechanism for first-flash and re-flash (`flash-node.sh`).
- Secrets never enter the Nix store or git in plaintext; stable SSH host keys
  across re-flash (no known_hosts churn).
- Drops the fragile stage-1 `neededForBoot` USB mount and `apply-identity`
  service.

**Negative / trade-offs**
- Each node needs a resident microSD (extra component; inserted at assembly).
- Existing Raspbian-on-NVMe nodes need a one-time touch (insert SD, set
  `0xf16`) — they cannot self-flash in place because kexec is unavailable.
- The age private key now lives on the same NVMe as the data (vs the old
  physically-separate USB). Acceptable for a LAN homelab; the encrypted
  bundle in-repo is the recovery source.
- The workstation needs `nix` installed (to run nixos-anywhere).

## Alternatives considered

- **Pi 5 network/HTTP boot** of the installer (zero media). Rejected for now:
  Pi 5 netboot of a NixOS netboot image is finicky and needs TFTP/HTTP infra
  on Heimdall. The resident SD is more reliable. Revisit later as an
  enhancement (EEPROM already supports a netboot order, `0xf6412`).
- **Raspbian-on-SD + dd a prebuilt NixOS image to NVMe.** Reuses the existing
  fleet OS but is image-based (the mechanism class the Debian path struggled
  with) and not nixos-anywhere. Rejected.
- **kexec from Raspbian.** Not viable on the Pi (see Decision §1).

## References

- nixos-anywhere #183 — kexec on Raspberry Pi OS.
- nixos-anywhere docs: secrets (`--extra-files`), reference (`--build-on-remote`,
  `--phases`).
- `nvmd/nixos-raspberrypi` `lib.nixosInstaller`, `nixosModules.sd-image`.
- Runbook: `Hyperion/docs/runbooks/remote-flash-a-node.md`.
