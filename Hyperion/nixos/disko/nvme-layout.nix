# disko/nvme-layout.nix — declarative NVMe partitioning for Hyperion workers.
#
# This is what the installer image runs against /dev/nvme0n1 on first
# install. Replaces the imperative `dd + parted + mkfs` in the Debian
# bootstrap.sh.
#
# Layout matches the Debian path's three-partition shape for continuity:
#   p1: FAT32 firmware partition (Pi 5 EEPROM reads kernel.img + config.txt here)
#   p2: ext4 root
#   p3: ext4 node-storage (mounted at /mnt/node-storage)

{ config, lib, ... }:

{
  disko.devices.disk.nvme0n1 = {
    device = "/dev/nvme0n1";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        firmware = {
          # Pi 5 firmware partition. The kernelboot builder writes
          # kernel.img and config.txt here.
          size = "512M";
          type = "0700";   # Microsoft basic data (FAT-compatible)
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot/firmware";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "32G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
        node-storage = {
          # All remaining space. Workload ephemeral storage.
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/mnt/node-storage";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
