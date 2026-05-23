# hyperion-journal.nix — ship journald entries to Heimdall's journal-remote.
#
# Heimdall (192.168.10.4:19532) hosts journal-remote per the prior dev
# pipeline (docs/pipeline-runs/20260521T144651Z-dev-hyperion-flashing-to-
# heimdall/). When the temporary Heimdall hosting reverts to Monolith or
# its successor (max 12 months), bump the URL here and `colmena apply`.

{ config, lib, pkgs, ... }:

{
  services.journald.upload = {
    enable = true;
    settings.Upload = {
      URL = "http://192.168.10.4:19532";
      # Plain HTTP on the lab VLAN. If we move to mTLS later, add:
      #   ServerKeyFile, ServerCertificateFile, TrustedCertificateFile
      # via sops-nix decryption from the USB-resident age key.
    };
  };

  # Local journal sizing — keep it bounded so a node going offline doesn't
  # fill its root partition.
  services.journald.extraConfig = ''
    SystemMaxUse=512M
    SystemKeepFree=1G
    RuntimeMaxUse=64M
  '';
}
