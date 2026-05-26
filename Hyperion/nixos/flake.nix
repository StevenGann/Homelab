{
  description = "Hyperion — 10-node Raspberry Pi 5 k3s worker cluster on NixOS";

  # See docs/pipeline-runs/20260523T050133Z-dev-nixos-identity-usb/FINAL.md
  # for the full design rationale. This flake is the Phase 1 scaffold; the
  # actual Phase 1 hard-gate validation happens on hyperion-alpha and is
  # documented in Hyperion/docs/runbooks/first-node-bringup-nixos.md.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Pi 5 substrate — only viable flake (predecessor raspberry-pi-nix
    # archived 2025-03-23). Pinned to v1.20260517.0 per iter-1 FC V-1.
    # Cachix substituter nixos-raspberrypi.cachix.org carries the rpi5
    # kernel; without it builds fall back to local compile (~25 min on
    # ubuntu-24.04-arm vs ~5 min cached).
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/v1.20260517.0";
    };

    # Secrets at activation time. Required: fileSystems."/var/lib/hyperion-id"
    # has neededForBoot = true (sops-nix reads the age key in stage-1 initrd).
    # Pin by commit — sops-nix ships no stable release tags, so we pin a
    # rev like colmena below. c591bf6 is the rev flake.lock already locks;
    # this just stops `nix flake update` from floating it freely, matching
    # the pinning discipline of every other input.
    sops-nix = {
      url = "github:Mic92/sops-nix/c591bf665727040c6cc5cb409079acb22dcce33c";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Day-2 deploys. Pin by commit because Colmena's last formal release
    # (v0.4.0, 2023-05-15) predates this work; 2025-11 commits keep the
    # repo alive. Tracking only; replace with a tag input when one ships.
    # Pin 349b035 (2025-11-01) merges PR #316 — replaces deprecated
    # pkgs.system with pkgs.stdenv.hostPlatform.system, required for clean
    # build against nixpkgs nixos-25.11.
    colmena = {
      url = "github:zhaofengli/colmena/349b035a5027f23d88eeb3bc41085d7ee29f18ed";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative NVMe partitioning. Imported by the worker closures (so
    # nixos-anywhere's disko phase partitions /dev/nvme0n1) — NOT by the
    # live SD installer.
    #
    # nixos-anywhere itself is intentionally NOT a flake input: flash-node.sh
    # invokes it with `nix run github:nix-community/nixos-anywhere/<rev>` at
    # flash time, so it never enters flake.lock or any built closure. The rev
    # is pinned in flash-node.sh.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixos-raspberrypi, sops-nix, colmena, disko, ... }:
    let
      system = "aarch64-linux";

      # The 10 worker hosts. Greek letter naming, IPs 192.168.10.101..110.
      # Per-host config divergence (k3s labels/taints, per-node Pi 5
      # overrides) lives in hosts/<hostname>.nix and is evaluated at build
      # time, not parsed at runtime.
      hostnames = [
        "hyperion-alpha"    # .101 — 8GB — Phase 1 validation node
        "hyperion-beta"     # .102 — 4GB — Phase 2 second-node test (memory-constraint surface)
        "hyperion-gamma"    # .103 — 4GB
        "hyperion-delta"    # .104 — 8GB
        "hyperion-epsilon"  # .105 — 8GB
        "hyperion-zeta"     # .106 — 8GB
        "hyperion-eta"      # .107 — 8GB
        "hyperion-theta"    # .108 — 8GB
        "hyperion-iota"     # .109 — 8GB
        "hyperion-kappa"    # .110 — 8GB
      ];

      # Modules shared by every worker. Per-host divergence happens in
      # hosts/<hostname>.nix.
      baseModules = [
        nixos-raspberrypi.nixosModules.raspberry-pi-5.base
        nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        ./modules/hyperion-base.nix
        ./modules/hyperion-identity.nix
        ./modules/hyperion-pi5.nix
        ./modules/hyperion-journal.nix
        ./modules/hyperion-k3s.nix
        ./disko/nvme-layout.nix
      ];

      # Helper: build a per-host nixosConfiguration.
      mkWorker = hostname: nixos-raspberrypi.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = baseModules ++ [
          ./hosts/${hostname}.nix
        ];
      };

      # The live SD-card installer. Identical across all 10 nodes; flashed to
      # a microSD once and inserted at assembly. It boots from SD, runs sshd,
      # and waits for ./flash-node.sh to drive nixos-anywhere against it.
      #
      # Deliberately does NOT import disko/nvme-layout.nix: that defines / as
      # the NVMe, but this image is SD-resident and must leave the NVMe blank
      # for nixos-anywhere's disko phase to partition.
      #
      # Uses `nixosInstaller` (not `nixosSystem`): it pulls in the upstream
      # sd-image module — which is what exposes config.system.build.sdImage —
      # plus the raspberrypi-installer module for live-boot behavior. The
      # plain `nixosSystem` helper used by the workers builds `toplevel` and
      # has no sdImage attribute.
      installer = nixos-raspberrypi.lib.nixosInstaller {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
          ./installer/installer.nix
        ];
      };
    in
    {
      nixosConfigurations = builtins.listToAttrs (map (h: {
        name = h;
        value = mkWorker h;
      }) hostnames);

      # Live SD-installer artifact: build with
      #   nix build .#installerSdImage
      # produces a microSD image. Flash it to an SD, insert at assembly, and
      # the node becomes SSH-reachable so ./flash-node.sh can install NixOS
      # onto its NVMe via nixos-anywhere.
      packages.${system}.installerSdImage = installer.config.system.build.sdImage;

      # Colmena hive — operator workstation pushes to nodes from here.
      colmena = {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
          specialArgs = { inherit inputs; };
        };
        defaults = { imports = baseModules; };
      } // builtins.listToAttrs (map (h: {
        name = h;
        value = { ... }: {
          deployment.targetHost = "192.168.10.${toString (100 + (
            # Map greek index alpha..kappa to .101..110
            # alpha=1 beta=2 gamma=3 delta=4 epsilon=5 zeta=6 eta=7 theta=8 iota=9 kappa=10
            { hyperion-alpha = 1; hyperion-beta = 2; hyperion-gamma = 3;
              hyperion-delta = 4; hyperion-epsilon = 5; hyperion-zeta = 6;
              hyperion-eta = 7; hyperion-theta = 8; hyperion-iota = 9;
              hyperion-kappa = 10; }.${h}
          ))}";
          deployment.targetUser = "owner";
          imports = [ ./hosts/${h}.nix ];
        };
      }) hostnames);
    };
}
