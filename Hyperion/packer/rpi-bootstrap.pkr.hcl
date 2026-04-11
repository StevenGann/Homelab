packer {
  required_plugins {
    arm-image = {
      version = ">= 0.2.7"
      source  = "github.com/solo-io/arm-image"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "image_url" {
  type    = string
  default = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz"
}

variable "image_checksum" {
  type    = string
  default = "sha256:681a775e20b53a9e4c7341d748a5a8cdc822039d8c67c1fd6ca35927abbe6290"
}

# ── Source ────────────────────────────────────────────────────────────────────

source "arm-image" "rpi_bootstrap" {
  iso_url      = var.image_url
  iso_checksum = var.image_checksum
  image_type   = "raspberrypi"

  qemu_binary = "qemu-aarch64-static"

  image_mounts = ["/boot/firmware", "/"]

  # Must be >= the uncompressed base image size (~2.79 GiB for Pi OS Trixie Lite).
  # The arm-image plugin cannot shrink partitions, only grow them.
  target_image_size = 3221225472  # 3 GiB

  output_filename = "output/rpi-bootstrap.img"

  resolv-conf = "copy-host"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  sources = ["source.arm-image.rpi_bootstrap"]

  # ── 1. Install required tools ─────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "apt-get update -qq",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq parted e2fsprogs dosfstools exfatprogs util-linux rpi-eeprom",
    ]
  }

  # ── 2. Disable unnecessary services to speed up boot ─────────────────────
  provisioner "shell" {
    inline = [
      "systemctl disable bluetooth.service 2>/dev/null || true",
      "systemctl disable avahi-daemon.service 2>/dev/null || true",
      "systemctl disable triggerhappy.service 2>/dev/null || true",
      "systemctl disable raspi-config.service 2>/dev/null || true",
    ]
  }

  # ── 3. Install bootstrap script and systemd unit ─────────────────────────
  provisioner "file" {
    source      = "files/bootstrap.sh"
    destination = "/usr/local/bin/bootstrap.sh"
  }
  provisioner "file" {
    source      = "files/bootstrap.service"
    destination = "/etc/systemd/system/hyperion-bootstrap.service"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /usr/local/bin/bootstrap.sh",
      "systemctl enable hyperion-bootstrap.service",
      # Enable network-online.target so bootstrap waits for a DHCP lease
      "systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true",
    ]
  }

  # ── 4. Create pi user and enable SSH (for emergency access during bootstrap) ─
  # Pi OS Trixie requires userconf.txt to activate SSH on first boot.
  # Password "raspberry" — this image is short-lived and LAN-only.
  provisioner "shell" {
    inline = [
      # Create pi user with sudo
      "useradd -m -s /bin/bash -G sudo pi",
      "echo 'pi:raspberry' | chpasswd",
      "echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_pi-nopasswd",
      "chmod 440 /etc/sudoers.d/010_pi-nopasswd",
      # Write userconf so Pi OS first-boot activates SSH
      "printf 'pi:%s\\n' \"$(echo 'raspberry' | openssl passwd -6 -stdin)\" > /boot/firmware/userconf.txt",
      "touch /boot/firmware/ssh",
      "systemctl enable ssh",
    ]
  }
}
