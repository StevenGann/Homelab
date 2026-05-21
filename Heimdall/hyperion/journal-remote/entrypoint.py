#!/usr/bin/env python3
# Supervisor for systemd-journal-remote + systemd-journal-gatewayd.
#
# Lifecycle contract:
#   - Both daemons start in parallel.
#   - If EITHER daemon exits, the supervisor exits non-zero. Compose's
#     restart policy then recreates the container, bouncing BOTH daemons.
#   - SIGTERM (from `docker stop`) is forwarded to both children; both get
#     up to ~9s to exit cleanly before docker delivers SIGKILL.
#
# Why register SIGCHLD before Popen: if a child exits between Popen and
# signal.signal(SIGCHLD, ...), the default SIG_IGN disposition reaps it
# silently and `signal.pause()` blocks forever waiting for a signal that
# already happened. This was Linux Expert's HIGH-priority finding in the
# Stage 5 re-review of the pipeline run (Tier 2.1 in FINAL.md). The fix is
# to install the handler before forking.
import os
import signal
import subprocess
import sys


DAEMONS = [
    ("journal-remote", [
        "/lib/systemd/systemd-journal-remote",
        "--listen-http=19532",
        "--output=/var/log/journal/remote/",
        "--split-mode=host",
    ]),
    ("journal-gatewayd", [
        "/lib/systemd/systemd-journal-gatewayd",
        "--directory=/var/log/journal/remote/",
    ]),
]


def log(msg: str) -> None:
    sys.stdout.write(f"[supervisor] {msg}\n")
    sys.stdout.flush()


children: dict[int, str] = {}
shutting_down = False


def on_sigchld(_signum, _frame):
    # Reap and check whether any tracked child exited. If so, propagate.
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        name = children.pop(pid, f"<unknown pid {pid}>")
        if os.WIFEXITED(status):
            code = os.WEXITSTATUS(status)
            log(f"{name} exited with status {code}")
        elif os.WIFSIGNALED(status):
            sig = os.WTERMSIG(status)
            log(f"{name} killed by signal {sig}")
        else:
            log(f"{name} reaped with raw status {status}")
        # Any tracked-daemon exit is supervisor-fatal — exit non-zero so
        # Compose recreates the container with both daemons fresh.
        if not shutting_down:
            _terminate_remaining()
            sys.exit(1)


def on_term(_signum, _frame):
    global shutting_down
    shutting_down = True
    log("SIGTERM received; forwarding to children")
    _terminate_remaining()
    # Don't exit immediately — wait for SIGCHLD to fire, which will then
    # exit(1) once the last child reaps. Match docker stop's grace period
    # by letting the children settle.


def _terminate_remaining() -> None:
    for pid, name in list(children.items()):
        try:
            os.kill(pid, signal.SIGTERM)
            log(f"sent SIGTERM to {name} (pid {pid})")
        except ProcessLookupError:
            pass


def main() -> None:
    # Install SIGCHLD/SIGTERM handlers BEFORE starting any child to avoid the
    # exit-before-handler race that Linux Expert flagged.
    signal.signal(signal.SIGCHLD, on_sigchld)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    for name, cmd in DAEMONS:
        log(f"starting {name}")
        proc = subprocess.Popen(cmd)
        children[proc.pid] = name
        log(f"{name} pid={proc.pid}")

    # Block waiting for signals. SIGCHLD or SIGTERM will exit() from their
    # handlers. We also defensively poll under signal.pause(): if a child
    # somehow died before the handler ran (race window between Popen and
    # the SIGCHLD handler installation — already mitigated above, but
    # defense-in-depth) we'd notice on the next signal.
    while True:
        signal.pause()


if __name__ == "__main__":
    main()
