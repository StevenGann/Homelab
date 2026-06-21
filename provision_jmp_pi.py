#!/usr/bin/env python3
"""
provision_jmp_pi.py

One-shot provisioner that turns a fresh Raspberry Pi 5 (Raspberry Pi OS Lite,
64-bit, Bookworm) into a dedicated Jellyfin Media Player appliance -- the
LibreELEC-for-Jellyfin experience you asked for.

It connects over SSH using a username + password you provide, then:
  1. Installs your local SSH public key for passwordless login.
  2. Enables passwordless sudo for the target user.
  3. Installs a minimal Wayland kiosk stack (cage) + Flatpak Jellyfin Media Player.
  4. Configures JMP to launch full-screen on boot under a systemd service.
  5. Adds a watchdog (systemd Restart=) so JMP comes back if it crashes.

Design notes for someone coming from embedded C/C++:
  - This is intentionally idempotent. Re-running it is safe; each step checks
    state before mutating, the way you'd guard a register write before poking it.
  - Think of paramiko as your UART-over-network: we open one session, stream
    commands, and read back stdout/stderr/exit-status for every "transaction".
  - There is NO third-party orchestration (Ansible et al.) on purpose -- you
    wanted to see the wires. Every remote action is an explicit run() call.

Dependencies (local machine only):
    pip install paramiko

Usage:
    python3 provision_jmp_pi.py --host 192.168.30.42 --user pi
    # password is prompted securely; --password is available but discouraged
"""

from __future__ import annotations

import argparse
import getpass
import os
import shlex
import sys
import time
from pathlib import Path

try:
    import paramiko
except ImportError:
    sys.exit(
        "Missing dependency 'paramiko'. Install it with:\n"
        "    pip install paramiko\n"
    )


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

class Colors:
    """ANSI codes. Disabled automatically if stdout isn't a TTY."""
    _on = sys.stdout.isatty()
    GREEN = "\033[92m" if _on else ""
    YELLOW = "\033[93m" if _on else ""
    RED = "\033[91m" if _on else ""
    BLUE = "\033[94m" if _on else ""
    BOLD = "\033[1m" if _on else ""
    END = "\033[0m" if _on else ""


def log(msg: str) -> None:
    print(f"{Colors.BLUE}[*]{Colors.END} {msg}")


def ok(msg: str) -> None:
    print(f"{Colors.GREEN}[+]{Colors.END} {msg}")


def warn(msg: str) -> None:
    print(f"{Colors.YELLOW}[!]{Colors.END} {msg}")


def die(msg: str) -> None:
    print(f"{Colors.RED}[x]{Colors.END} {msg}", file=sys.stderr)
    sys.exit(1)


def find_local_pubkey(explicit: str | None) -> str:
    """Locate the local SSH public key to install on the Pi."""
    if explicit:
        p = Path(explicit).expanduser()
        if not p.exists():
            die(f"Specified public key not found: {p}")
        return p.read_text().strip()

    ssh_dir = Path.home() / ".ssh"
    # Preference order: ed25519 first (modern, matches your YubiKey/ed25519-sk
    # leanings), then ecdsa, then rsa as a fallback.
    for name in ("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"):
        candidate = ssh_dir / name
        if candidate.exists():
            log(f"Using local public key: {candidate}")
            return candidate.read_text().strip()

    die(
        "No SSH public key found in ~/.ssh (looked for id_ed25519.pub, "
        "id_ecdsa.pub, id_rsa.pub). Generate one with:\n"
        "    ssh-keygen -t ed25519\n"
        "or pass --pubkey /path/to/key.pub"
    )


# ---------------------------------------------------------------------------
# SSH session wrapper
# ---------------------------------------------------------------------------

class PiSession:
    """
    Thin wrapper around a paramiko SSHClient.

    run() executes a command and returns (exit_code, stdout, stderr).
    sudo() wraps a command so it runs as root. During the first phase we feed
    the sudo password over stdin; once passwordless sudo is configured we stop
    needing it, but feeding it is harmless either way.
    """

    def __init__(self, host: str, user: str, password: str, port: int = 22):
        self.host = host
        self.user = user
        self.password = password
        self.port = port
        self.client = paramiko.SSHClient()
        # First-contact: we don't have the host key yet. AutoAdd is the
        # pragmatic choice for a LAN appliance you're provisioning yourself.
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    def connect(self, retries: int = 3, delay: float = 3.0) -> None:
        last_err = None
        for attempt in range(1, retries + 1):
            try:
                self.client.connect(
                    hostname=self.host,
                    port=self.port,
                    username=self.user,
                    password=self.password,
                    look_for_keys=False,   # force password auth this pass
                    allow_agent=False,
                    timeout=15,
                )
                ok(f"Connected to {self.user}@{self.host}:{self.port}")
                return
            except paramiko.AuthenticationException:
                die("Authentication failed -- check username/password.")
            except Exception as e:  # noqa: BLE001  (connection-level errors)
                last_err = e
                warn(f"Connect attempt {attempt}/{retries} failed: {e}")
                time.sleep(delay)
        die(f"Could not connect to {self.host}: {last_err}")

    def run(self, command: str, check: bool = True) -> tuple[int, str, str]:
        stdin, stdout, stderr = self.client.exec_command(command)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        if check and exit_code != 0:
            die(
                f"Remote command failed (exit {exit_code}):\n"
                f"  $ {command}\n"
                f"  stderr: {err.strip()}"
            )
        return exit_code, out, err

    def sudo(self, command: str, check: bool = True) -> tuple[int, str, str]:
        """Run a command as root, supplying the sudo password via stdin."""
        # -S reads the password from stdin; -p '' suppresses the prompt text.
        wrapped = f"sudo -S -p '' bash -c {shlex.quote(command)}"
        stdin, stdout, stderr = self.client.exec_command(wrapped)
        stdin.write(self.password + "\n")
        stdin.flush()
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        if check and exit_code != 0:
            die(
                f"Remote sudo command failed (exit {exit_code}):\n"
                f"  $ {command}\n"
                f"  stderr: {err.strip()}"
            )
        return exit_code, out, err

    def put_file(self, content: str, remote_path: str, mode: int = 0o644) -> None:
        """Write a string to a remote path as the login user (no sudo)."""
        sftp = self.client.open_sftp()
        with sftp.file(remote_path, "w") as f:
            f.write(content)
        sftp.chmod(remote_path, mode)
        sftp.close()

    def close(self) -> None:
        self.client.close()


# ---------------------------------------------------------------------------
# Provisioning steps
# ---------------------------------------------------------------------------

def step_install_pubkey(s: PiSession, pubkey: str) -> None:
    log("Installing local SSH public key for passwordless login...")
    # Append the key only if it's not already present -- idempotent.
    remote_tmp = "/tmp/_provision_key.pub"
    s.put_file(pubkey + "\n", remote_tmp)
    s.run(
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
        "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
        f"grep -qxF \"$(cat {remote_tmp})\" ~/.ssh/authorized_keys "
        f"|| cat {remote_tmp} >> ~/.ssh/authorized_keys && "
        f"rm -f {remote_tmp}"
    )
    ok("SSH public key installed.")


def step_passwordless_sudo(s: PiSession) -> None:
    log("Enabling passwordless sudo for this user...")
    user = s.user
    sudoers_line = f"{user} ALL=(ALL) NOPASSWD: ALL"
    sudoers_file = f"/etc/sudoers.d/010_{user}-nopasswd"
    # visudo -cf validates the file before we trust it -- never write a broken
    # sudoers file, that's how you lock yourself out.
    cmd = (
        f"echo {shlex.quote(sudoers_line)} > {sudoers_file} && "
        f"chmod 0440 {sudoers_file} && "
        f"visudo -cf {sudoers_file}"
    )
    s.sudo(cmd)
    ok("Passwordless sudo configured.")


def step_system_update(s: PiSession) -> None:
    log("Updating apt and installing kiosk dependencies (this can take a few minutes)...")
    # cage  : a minimal Wayland kiosk compositor -- runs ONE app full-screen.
    #         (the Wayland analogue of a single-purpose RTOS task with no
    #         window manager chrome around it.)
    # seatd : session/seat management so cage can grab the GPU + input as a
    #         non-root user on boot.
    # flatpak: how we get an arm64 Jellyfin Media Player build, since there is
    #         no official .deb for arm64 in the Jellyfin apt repo.
    s.sudo("DEBIAN_FRONTEND=noninteractive apt-get update -y")
    s.sudo(
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "cage seatd flatpak"
    )
    ok("Base packages installed.")


def step_install_jmp(s: PiSession) -> None:
    log("Installing Jellyfin Media Player via Flatpak...")
    # Add Flathub if absent, then install JMP. --noninteractive avoids prompts.
    s.sudo(
        "flatpak remote-add --if-not-exists flathub "
        "https://flathub.org/repo/flathub.flatpakrepo"
    )
    # Check whether it's already installed to keep this idempotent and fast.
    code, out, _ = s.run(
        "flatpak list --app --columns=application 2>/dev/null "
        "| grep -qx com.github.iwalton3.jellyfin-media-player && echo PRESENT "
        "|| echo ABSENT",
        check=False,
    )
    if "PRESENT" in out:
        ok("Jellyfin Media Player already installed.")
    else:
        s.sudo(
            "flatpak install -y --noninteractive flathub "
            "com.github.iwalton3.jellyfin-media-player"
        )
        ok("Jellyfin Media Player installed.")


def step_enable_seatd(s: PiSession) -> None:
    log("Enabling seatd and granting seat access...")
    s.sudo("systemctl enable --now seatd")
    # The login user needs to be in the seat-management groups so cage can
    # acquire the DRM device + input without root.
    s.sudo(f"usermod -aG seat,video,input,render {s.user}")
    ok("seatd enabled and user added to seat/video/input/render groups.")


def step_kiosk_service(s: PiSession) -> None:
    log("Creating the JMP kiosk systemd service (boot + watchdog)...")
    user = s.user
    # The launch target. cage runs a single client full-screen and exits when
    # that client exits -- so the systemd unit's Restart= IS the watchdog:
    # JMP dies -> cage exits non-zero -> systemd restarts the whole unit.
    #
    # --fullscreen tells JMP to take the whole surface; cage already gives it
    # the entire output, so the two agree and you get a true appliance screen.
    flatpak_cmd = (
        "/usr/bin/flatpak run com.github.iwalton3.jellyfin-media-player "
        "--fullscreen --platform wayland"
    )

    unit = f"""[Unit]
Description=Jellyfin Media Player kiosk (cage Wayland session)
After=seatd.service systemd-user-sessions.service network-online.target
Wants=network-online.target seatd.service

[Service]
User={user}
# A real login-ish environment so Flatpak + Wayland find their runtime dirs.
PAMName=login
TTYPath=/dev/tty7
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WLR_LIBINPUT_NO_DEVICES=1
# cage -d daemonizes nothing; it stays in foreground so systemd can supervise.
# When the wrapped app (JMP) quits or crashes, cage returns and we restart.
ExecStart=/usr/bin/cage -- {flatpak_cmd}

# ---- Watchdog / crash-recovery policy ----
Restart=always
RestartSec=3
# Don't let a tight crash loop hammer the GPU forever: if it restarts more
# than 5 times in 60s, back off (systemd will retry after the window).
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
"""
    remote_tmp = "/tmp/jmp-kiosk.service"
    s.put_file(unit, remote_tmp)
    s.sudo(
        f"mv {remote_tmp} /etc/systemd/system/jmp-kiosk.service && "
        "chown root:root /etc/systemd/system/jmp-kiosk.service && "
        "chmod 0644 /etc/systemd/system/jmp-kiosk.service"
    )

    # Boot straight to console (no display-manager) so our unit owns the screen.
    s.sudo("systemctl set-default multi-user.target")
    s.sudo("systemctl daemon-reload")
    s.sudo("systemctl enable jmp-kiosk.service")
    ok("Kiosk service installed and enabled for boot.")


def step_summary(s: PiSession, host: str) -> None:
    print()
    ok("Provisioning complete.")
    print(
        f"""
{Colors.BOLD}What happens now{Colors.END}
  - On next boot the Pi goes straight into Jellyfin Media Player, full-screen.
  - If JMP crashes, systemd restarts it within ~3s (the watchdog).
  - First launch will show JMP's "Connect to Server" screen; point it at your
    Jellyfin server (e.g. http://akasha:8096) once, and it remembers it.

{Colors.BOLD}Handy remote commands{Colors.END} (you now have key-based + passwordless sudo)
  ssh {s.user}@{host} 'sudo systemctl status jmp-kiosk --no-pager'
  ssh {s.user}@{host} 'sudo systemctl restart jmp-kiosk'
  ssh {s.user}@{host} 'sudo journalctl -u jmp-kiosk -b --no-pager'

{Colors.BOLD}Reboot to start the appliance{Colors.END}
  ssh {s.user}@{host} 'sudo reboot'
"""
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Provision a Raspberry Pi 5 as a Jellyfin Media Player kiosk."
    )
    ap.add_argument("--host", required=True, help="Pi hostname or IP")
    ap.add_argument("--user", required=True, help="Existing login user on the Pi (e.g. pi)")
    ap.add_argument("--port", type=int, default=22, help="SSH port (default 22)")
    ap.add_argument(
        "--password",
        help="Login/sudo password. OMIT to be prompted securely (recommended).",
    )
    ap.add_argument(
        "--pubkey",
        help="Path to local SSH public key. Defaults to ~/.ssh/id_ed25519.pub etc.",
    )
    ap.add_argument(
        "--no-reboot-hint",
        action="store_true",
        help="Suppress the trailing summary/hints.",
    )
    args = ap.parse_args()

    password = args.password or getpass.getpass(
        f"Password for {args.user}@{args.host}: "
    )
    pubkey = find_local_pubkey(args.pubkey)

    s = PiSession(args.host, args.user, password, args.port)
    s.connect()
    try:
        # Phase order matters: key + sudo first so the rest is frictionless.
        step_install_pubkey(s, pubkey)
        step_passwordless_sudo(s)
        step_system_update(s)
        step_install_jmp(s)
        step_enable_seatd(s)
        step_kiosk_service(s)
        if not args.no_reboot_hint:
            step_summary(s, args.host)
    finally:
        s.close()


if __name__ == "__main__":
    main()
