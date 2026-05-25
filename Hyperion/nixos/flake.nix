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
    sops-nix = {
      url = "github:Mic92/sops-nix";
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

    # Declarative NVMe partitioning for first-install via installer image.
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

      # The installer image flashed to a blank NVMe once per kernel/firmware
      # bump (~quarterly). Identical across all 10 nodes — per-host divergence
      # is post-install via Colmena.
      installer = nixos-raspberrypi.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
          disko.nixosModules.disko
          ./disko/nvme-layout.nix
          ./installer/installer.nix
        ];
      };
    in
    {
      nixosConfigurations = builtins.listToAttrs (map (h: {
        name = h;
        value = mkWorker h;
      }) hostnames);

      # Installer image artifact: build with
      #   nix build .#installerImage
      # produces an SD-card image that, when dd'd to a blank NVMe and the
      # NVMe is moved into a Pi 5, boots into NixOS as a fresh worker.
      packages.${system}.installerImage = installer.config.system.build.sdImage;

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
