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
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq parted e2fsprogs dosfstools exfatprogs util-linux rpi-eeprom python3",
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
      # Ensure pi user exists with sudo and known password
      "id pi >/dev/null 2>&1 || useradd -m -s /bin/bash pi",
      "usermod -aG sudo pi",
      "echo 'pi:raspberry' | chpasswd",
      "echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_pi-nopasswd",
      "chmod 440 /etc/sudoers.d/010_pi-nopasswd",
      # Write userconf so Pi OS first-boot activates SSH
      "printf 'pi:%s\\n' \"$(echo 'raspberry' | openssl passwd -6 -stdin)\" > /boot/firmware/userconf.txt",
      "touch /boot/firmware/ssh",
      "systemctl enable ssh",
    ]
  }

  # ── 5. Enable UART boot output (zero-cost diagnostic surface) ─────────────
  # `enable_uart=1` exposes the kernel console on GPIO 14/15 at 115200 baud.
  # `console=serial0,115200` adds the serial port to the kernel command line.
  # Operators can attach a $5 USB-TTL adapter (CP2102 / FT232) to capture full
  # boot output when SSH/HTTP diagnostics are inconclusive — only channel that
  # catches firmware-stage failures (e.g. NVMe enumeration issues per
  # rpi-eeprom #629/#718). Idempotent grep-q-||-... pattern matches the
  # Node IMG's config.txt edits to avoid duplicate entries on Packer re-runs.
  provisioner "shell" {
    inline = [
      "grep -q 'enable_uart=1' /boot/firmware/config.txt || echo 'enable_uart=1' >> /boot/firmware/config.txt",
      "grep -q 'console=serial0,115200' /boot/firmware/cmdline.txt || sed -i '$ s/$/ console=serial0,115200/' /boot/firmware/cmdline.txt",
    ]
  }

  # ── 6. systemd-journal-upload — networked log shipping (Phase 1) ──────────
  # Ships the bootstrap journal (including hyperion-bootstrap.service stdout
  # via StandardOutput=journal+console) to the journal-remote service on
  # Monolith. Acceptable for LAN-only HTTP because the Bootstrap medium is
  # short-lived and never carries production data. The bootstrap script's
  # in-band /log HTTP route covers the early-boot window before journal-upload
  # has network connectivity.
  provisioner "shell" {
    inline = [
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd-journal-remote",
      "mkdir -p /etc/systemd/journal-upload.conf.d",
      # Plain HTTP (no TLS) — LAN-only homelab. Trust= is only relevant for
      # HTTPS; omit it. The default systemd-journal-upload behavior with an
      # http:// URL ships logs without TLS validation.
      # Journal-upload target is Heimdall (192.168.10.4) since the
      # dev-hyperion-flashing-to-heimdall pipeline cut over. The conf-d file
      # is still named monolith.conf for now; renamed once Monolith is gone.
      "printf '[Upload]\\nURL=http://192.168.10.4:19532\\n' > /etc/systemd/journal-upload.conf.d/monolith.conf",
      "systemctl enable systemd-journal-upload.service",
    ]
  }
}
