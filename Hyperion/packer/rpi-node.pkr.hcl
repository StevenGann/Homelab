packer {
  required_plugins {
    arm-image = {
      version = ">= 0.2.7"
      source  = "github.com/solo-io/arm-image"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  type        = string
  description = "SSH public key baked into the image for the owner user."
}

variable "image_version" {
  type        = string
  description = "Unix epoch integer (date +%s) — written to /boot/firmware/node-img.ver."
}

variable "image_url" {
  type    = string
  default = "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz"
}

variable "image_checksum" {
  type    = string
  default = "sha256:681a775e20b53a9e4c7341d748a5a8cdc822039d8c67c1fd6ca35927abbe6290"
}

# ── Source ────────────────────────────────────────────────────────────────────

source "arm-image" "rpi_node" {
  iso_url      = var.image_url
  iso_checksum = var.image_checksum
  image_type   = "raspberrypi"

  qemu_binary = "qemu-aarch64-static"

  # Pi OS Trixie mounts boot firmware partition separately
  image_mounts = ["/boot/firmware", "/"]

  # ~4 GB: covers p1 (512 MB FAT32) + p2 (root OS).
  # Bootstrap handles final NVMe partitioning: resizes p2 to 32 GiB, creates p3.
  target_image_size = 4294967296

  output_filename = "output/rpi-node.img"

  resolv-conf = "copy-host"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  sources = ["source.arm-image.rpi_node"]

  # ── 1. Create owner user ───────────────────────────────────────────────────
  # Pi OS Trixie no longer ships with a default "pi" user (changed in Bookworm).
  # Create "owner" as the primary user; delete "pi" if it exists (no-op on Trixie).
  provisioner "shell" {
    inline = [
      "useradd -m -s /bin/bash -G sudo owner",
      "echo 'owner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/owner",
      "chmod 440 /etc/sudoers.d/owner",
    ]
  }

  # ── 2. Add SSH authorized key for owner ───────────────────────────────────
  provisioner "shell" {
    inline = [
      "mkdir -p /home/owner/.ssh",
      "echo '${var.ssh_public_key}' > /home/owner/.ssh/authorized_keys",
      "chmod 700 /home/owner/.ssh",
      "chmod 600 /home/owner/.ssh/authorized_keys",
      "chown -R owner:owner /home/owner/.ssh",
    ]
  }

  # ── 3. Delete pi user ─────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "userdel -r pi 2>/dev/null || true",
      "rm -f /etc/sudoers.d/010_pi-nopasswd",
    ]
  }

  # ── 4. Install packages ───────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "apt-get update -qq",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq git nfs-common open-iscsi zstd exfatprogs",
    ]
  }

  # ── 5. Purge cloud-init ───────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq cloud-init",
      "rm -rf /etc/cloud /var/lib/cloud",
    ]
  }

  # ── 6. Install k3s (units created, not enabled) ───────────────────────────
  provisioner "shell" {
    inline = [
      "curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh",
      "chmod +x /tmp/k3s-install.sh",
      "INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true /tmp/k3s-install.sh",
      "rm -f /tmp/k3s-install.sh",
    ]
  }

  # ── 7. Write version stamp ────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '${var.image_version}' > /boot/firmware/node-img.ver",
    ]
  }

  # ── 8. Update config.txt for Pi 5 NVMe boot ──────────────────────────────
  # The [pi5] conditional section targets Pi 5 (BCM2712) only.
  # - kernel=kernel_2712.img: redundant on Trixie (firmware auto-selects), kept
  #   for explicitness and backward compat with Bookworm.
  # - auto_initramfs=1: required for initramfs-based boot on Pi 5.
  # - dtparam=pciex1_gen=3: overclocks PCIe from Gen 2 (spec) to Gen 3.
  #   NOT guaranteed by the BCM2712 datasheet — may fail link training on some
  #   NVMe drives. If a node fails to detect its NVMe, try removing this line.
  #   Validated drive model(s): (TODO: document the specific NVMe model in use)
  # - dtparam=nvme: redundant on Trixie (NVMe driver loads automatically via
  #   device tree), kept for backward compat with Bookworm.
  provisioner "shell" {
    inline = [
      # Ensure [pi5] section exists, then append NVMe boot directives.
      # grep -q avoids duplicate entries on re-runs.
      "grep -q '\\[pi5\\]' /boot/firmware/config.txt || echo '[pi5]' >> /boot/firmware/config.txt",
      "grep -q 'kernel=kernel_2712.img' /boot/firmware/config.txt   || echo 'kernel=kernel_2712.img'   >> /boot/firmware/config.txt",
      "grep -q 'auto_initramfs=1'       /boot/firmware/config.txt   || echo 'auto_initramfs=1'         >> /boot/firmware/config.txt",
      "grep -q 'dtparam=pciex1_gen=3'  /boot/firmware/config.txt   || echo 'dtparam=pciex1_gen=3'     >> /boot/firmware/config.txt",
      "grep -q 'dtparam=nvme'           /boot/firmware/config.txt   || echo 'dtparam=nvme'             >> /boot/firmware/config.txt",
    ]
  }

  # ── 9. cgroup parameters for k3s ─────────────────────────────────────────
  # NOTE: Pi OS Trixie (kernel 6.6+) uses cgroup v2 unified hierarchy by
  # default. These cgroup v1 parameters are silently ignored on cgroup v2 —
  # memory cgroup is always enabled. Kept for backward compatibility if the
  # base image is ever switched to Bookworm (cgroup v1).
  provisioner "shell" {
    inline = [
      "grep -q 'cgroup_memory=1' /boot/firmware/cmdline.txt || sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt",
    ]
  }

  # ── 10. Disable root partition auto-expansion ─────────────────────────────
  # Bootstrap handles partitioning explicitly (p2=32 GiB, p3=remainder).
  # Suppress ALL auto-expansion mechanisms:
  # - Legacy: init_resize.sh (Jessie–Bullseye), resize2fs_once (Stretch–Bullseye)
  # - Modern: systemd-repart (Trixie) — masks the service AND removes repart
  #   config files to prevent first-boot partition expansion on NVMe.
  provisioner "shell" {
    inline = [
      "sed -i 's| init=/usr/lib/raspi-config/init_resize\\.sh||g' /boot/firmware/cmdline.txt",
      "systemctl disable raspberrypi-sys-mods-firstboot.service 2>/dev/null || true",
      "systemctl disable resize2fs_once.service 2>/dev/null || true",
      "rm -f /etc/init.d/resize2fs_once",
      "systemctl mask systemd-repart.service 2>/dev/null || true",
      "rm -rf /usr/lib/repart.d/",
    ]
  }

  # ── 11. Enable SSH ────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "touch /boot/firmware/ssh",
      "systemctl enable ssh",
    ]
  }

  # ── 12. Install identity + storage systemd units ──────────────────────────
  provisioner "file" {
    source      = "files/apply-identity.sh"
    destination = "/usr/local/bin/apply-identity.sh"
  }
  provisioner "file" {
    source      = "files/apply-identity.service"
    destination = "/etc/systemd/system/apply-identity.service"
  }
  provisioner "file" {
    source      = "files/detect-node-storage.sh"
    destination = "/usr/local/bin/detect-node-storage.sh"
  }
  provisioner "file" {
    source      = "files/detect-node-storage.service"
    destination = "/etc/systemd/system/detect-node-storage.service"
  }
  provisioner "file" {
    source      = "files/mnt-node-storage.mount"
    destination = "/etc/systemd/system/mnt-node-storage.mount"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /usr/local/bin/apply-identity.sh",
      "chmod +x /usr/local/bin/detect-node-storage.sh",
      "systemctl enable apply-identity.service",
      "systemctl enable detect-node-storage.service",
      "systemctl enable mnt-node-storage.mount",
    ]
  }

  # ── 13. Create mount point and set locale/timezone ────────────────────────
  provisioner "shell" {
    inline = [
      "mkdir -p /mnt/node-storage",
      "timedatectl set-timezone UTC 2>/dev/null || echo 'UTC' > /etc/timezone",
      "locale-gen en_US.UTF-8 2>/dev/null || true",
    ]
  }
}
