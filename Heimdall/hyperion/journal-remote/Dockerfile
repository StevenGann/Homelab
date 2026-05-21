# Purpose-built systemd-journal-remote receiver for Hyperion node logs.
#
# Bundles TWO daemons in one image (per the Hyperion-flashing-to-Heimdall
# pipeline FINAL.md Tier 4.1):
#   - systemd-journal-remote on TCP :19532  — receives journal-upload pushes
#                                              from each Pi during flashing
#   - systemd-journal-gatewayd on TCP :19531 — HTML5 UI for browsing the
#                                              accumulated journal entries
#                                              (cross-attempt history, search,
#                                              filter by host/unit/etc.)
#
# Both daemons ship in the SAME Debian package (`systemd-journal-remote`) so
# this is a one-package install — no second apt step.
#
# Why one container instead of two?
#   - Tightly coupled lifecycle (gatewayd reads journal-remote's output dir).
#   - One CI workflow, one tag, one image to track.
#   - Failure-mode trade-off: if either daemon crashes the container exits and
#     Compose recreates both, bouncing journal upload for ~5–10s. journal-
#     upload on each Pi buffers and retries, so the bounce is invisible.
#   - V2 escape hatch (Heimdall/docs/runbooks/flashing-services.md): if either
#     daemon crashes more than weekly, split into two containers (same image,
#     different entrypoint flag).
#
# Why python supervisor instead of bare `tini` + two CMDs?
#   - tini can supervise one PID 1 child. Running two daemons under one tini
#     requires either an `&`-and-wait shell wrapper (signal forwarding is
#     surprisingly fragile) or a real supervisor that owns SIGCHLD/SIGTERM.
#   - The python supervisor is ~70 lines and addresses three concerns from the
#     pipeline FINAL.md Tier 2:
#       T2.1 — SIGCHLD handler is registered BEFORE Popen, so a child that
#              exits immediately doesn't leave the supervisor blocked in
#              signal.pause() forever.
#       T2.2 — SIGTERM forwarded to children (docker stop's 10s grace works).
#       T2.4 — python3-minimal and tini installed explicitly.
#
# Plain HTTP both — LAN-only homelab. If the threat model expands beyond the
# homelab VLAN, switch journal-remote to `--listen-https=` and front gatewayd
# with Caddy + an internal CA (~20 lines of additional config).

FROM debian:trixie-slim

# Single apt step: systemd-journal-remote bundles both daemons; tini for PID 1
# signal forwarding; python3-minimal for the supervisor.
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        systemd-journal-remote \
        tini \
        python3-minimal && \
    rm -rf /var/lib/apt/lists/*

# /var/log/journal/remote is owned by systemd-journal-remote per the package's
# tmpfiles.d entry; we just need it to exist on the bind-mounted volume so the
# host bind-mount inherits ownership cleanly on first container start.
RUN install -d -o systemd-journal-remote -g systemd-journal-remote -m 2755 \
        /var/log/journal/remote

COPY entrypoint.py /usr/local/bin/entrypoint.py
RUN chmod 0555 /usr/local/bin/entrypoint.py

EXPOSE 19531 19532
USER systemd-journal-remote

# tini as PID 1 → python supervisor → both daemons. tini reaps zombies,
# forwards signals to its single child (the supervisor), and exits when the
# supervisor exits. Compose's `restart: unless-stopped` then recreates.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/python3", "/usr/local/bin/entrypoint.py"]
