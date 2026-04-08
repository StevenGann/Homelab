packer {
  required_plugins {
    arm-image = {
      version = ">= 0.2.7"
      source  = "github.com/solo-io/arm-image"
    }
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to bake into the image for the pi user"
}

variable "image_url" {
  type    = string
  default = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz"
}

variable "image_checksum" {
  type    = string
  default = "sha256:681a775e20b53a9e4c7341d748a5a8cdc822039d8c67c1fd6ca35927abbe6290"
}

source "arm-image" "rpi_base" {
  iso_url      = var.image_url
  iso_checksum = var.image_checksum
  image_type   = "raspberrypi"

  # Pi 5 is arm64
  qemu_binary = "qemu-aarch64-static"

  # Pi OS Trixie mounts boot firmware partition separately
  image_mounts = ["/boot/firmware", "/"]

  # 4GB is enough to hold the base OS with all packages.
  # The imaging script handles final partitioning on the NVMe.
  target_image_size = 4294967296

  output_filename = "output/rpi-base.img"

  # Use host DNS during build so apt-get can resolve package mirrors
  resolv-conf = "copy-host"
}

build {
  sources = ["source.arm-image.rpi_base"]

  # Enable SSH
  provisioner "shell" {
    inline = [
      "touch /boot/firmware/ssh",
    ]
  }

  # Set authorized SSH key for pi user
  provisioner "shell" {
    inline = [
      "mkdir -p /home/pi/.ssh",
      "chmod 700 /home/pi/.ssh",
      "echo '${var.ssh_public_key}' > /home/pi/.ssh/authorized_keys",
      "chmod 600 /home/pi/.ssh/authorized_keys",
      "chown -R pi:pi /home/pi/.ssh",
    ]
  }

  # Install packages
  provisioner "shell" {
    inline = [
      "apt-get update -qq",
      "apt-get install -y -qq cloud-init curl jq git nfs-common open-iscsi",
    ]
  }

  # Kernel parameters for k3s (cgroups)
  provisioner "shell" {
    inline = [
      "sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt",
    ]
  }

  # Disable root partition auto-expansion on first boot.
  # The imaging script handles partitioning explicitly — we don't want
  # raspi-config's resize service fighting with our layout.
  provisioner "shell" {
    inline = [
      "rm -f /etc/init.d/resize2fs_once",
      "systemctl disable raspberrypi-sys-mods-firstboot.service || true",
      "systemctl disable resize2fs_once.service || true",
      "sed -i 's| init=/usr/lib/raspi-config/init_resize\\.sh||g' /boot/firmware/cmdline.txt",
    ]
  }

  # Create node-storage mount point
  provisioner "shell" {
    inline = [
      "mkdir -p /mnt/node-storage",
    ]
  }

  # Enable cloud-init datasource for NoCloud (reads from cidata USB stick)
  provisioner "shell" {
    inline = [
      "echo 'datasource_list: [NoCloud, None]' > /etc/cloud/cloud.cfg.d/99-datasource.cfg",
    ]
  }

  # Pre-download k3s binary to speed up provisioning
  provisioner "shell" {
    inline = [
      "curl -sfL https://github.com/k3s-io/k3s/releases/latest/download/k3s-arm64 -o /usr/local/bin/k3s",
      "chmod +x /usr/local/bin/k3s",
    ]
  }

  # Set locale and timezone
  provisioner "shell" {
    inline = [
      "timedatectl set-timezone UTC || echo 'UTC' > /etc/timezone",
      "locale-gen en_US.UTF-8 || true",
    ]
  }
}
