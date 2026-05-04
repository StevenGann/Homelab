# Purpose-built systemd-journal-remote receiver for Hyperion node logs.
#
# Design choices (per dbg-nvme-not-flashing pipeline FINAL.md):
#   - Bake the package at build time, NOT apt-get-at-container-start. A logging
#     endpoint must not depend on Debian repo availability at runtime — that
#     inverts the dependency (network outage during a Pi failure means the
#     receiver can't restart and you lose the logs you most need).
#   - Pin the base image. trixie-slim is current Debian stable as of 2026.
#   - Run as the systemd-journal-remote user (created by the package).
#
# Listens on plain HTTP :19532 — LAN-only homelab. If the threat model ever
# expands beyond the homelab VLAN, switch to --listen-https with a self-signed
# CA (~10 lines of openssl + a Dockerfile addition).

FROM debian:trixie-slim

# Pinning apt during the build only.
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        systemd-journal-remote && \
    rm -rf /var/lib/apt/lists/*

# /var/log/journal/remote is owned by systemd-journal-remote per the package's
# tmpfiles.d entry; we just need it to exist on the bind-mounted volume.
RUN install -d -o systemd-journal-remote -g systemd-journal-remote -m 2755 \
        /var/log/journal/remote

# --listen-http=19532 — bind plain HTTP on TCP port 19532 (NOT --listen-http=-3
# which is the FD-inherit form for systemd socket activation; that does not
# work inside a Docker container with no inherited LISTEN_FDS).
# --output: directory; with --split-mode=host, one .journal file per source.
EXPOSE 19532
USER systemd-journal-remote
ENTRYPOINT ["/lib/systemd/systemd-journal-remote", \
            "--listen-http=19532", \
            "--output=/var/log/journal/remote/", \
            "--split-mode=host"]
