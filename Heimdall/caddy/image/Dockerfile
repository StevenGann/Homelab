# Heimdall — custom Caddy image
#
# Built by .github/workflows/build-heimdall-caddy-img.yml on path-filtered push to main.
# Published to: ghcr.io/stevengann/homelab-heimdall-caddy:v2.11.3-l4-0.1.1
#
# Pin policy:
#   - Base image: Caddy v2.11.3 (current stable as of 2026-05-12).
#   - Plugin: caddy-l4 v0.1.1 (current stable as of 2026-05-14).
# Both pins are tracked: caddy-l4 by .github/workflows/poll-caddy-l4-releases.yml
# (scheduled GHA polling), Caddy base image by Dependabot (FROM line).
#
# See ./README.md for the upgrade policy.

FROM caddy:2.11.3-builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-l4@v0.1.1

FROM caddy:2.11.3

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
