# Heimdall Caddy image — upgrade policy

This directory holds the Dockerfile for the custom Caddy image that runs on Heimdall. The image bakes the [`caddy-l4`](https://github.com/mholt/caddy-l4) plugin into the official Caddy base so Caddy can handle both HTTPS reverse-proxying and raw TCP/UDP forwarding in a single binary.

## How it's built

`.github/workflows/build-heimdall-caddy-img.yml` is path-filtered on `Heimdall/caddy/image/**`. Any push to `main` that touches this directory triggers a build → push to `ghcr.io/stevengann/homelab-heimdall-caddy:<version-tag>`. The image is then pulled by Heimdall's Compose stack at deploy time.

**No `:latest` tag is published.** Pins are explicit per the project's "no floating tags" rule.

## Pin policy

Two pins are tracked:

| Component | Pin | Tracked by |
|---|---|---|
| Caddy base image (`FROM caddy:X.Y.Z-builder` and `FROM caddy:X.Y.Z`) | v2.11.3 | Dependabot `package-ecosystem: docker` on this directory (`.github/dependabot.yml`). New stable Caddy releases surface as PRs against this Dockerfile. |
| `caddy-l4` plugin (`xcaddy build --with github.com/mholt/caddy-l4@vX.Y.Z`) | v0.1.1 | `.github/workflows/poll-caddy-l4-releases.yml` (scheduled GHA, weekly). New `caddy-l4` tags surface as PRs that bump both this Dockerfile and the image tag in `Heimdall/docker-compose.yml`. |

Dependabot's `docker` ecosystem does NOT parse `xcaddy --with` lines — only `FROM` lines. The polling workflow is the load-bearing mechanism for plugin version tracking. (See the pipeline-run `FINAL.md` known concern #3 for the history of this fix.)

## Upgrading

When a PR lands here (from Dependabot or the polling workflow):

1. **Review the upstream release notes** for the bumped component.
   - Caddy: <https://github.com/caddyserver/caddy/releases>
   - caddy-l4: <https://github.com/mholt/caddy-l4/releases> — pay attention to the README's "expect breaking changes" hedge; the plugin is pre-1.0.
2. **Verify the image tag in `Heimdall/docker-compose.yml`** matches the new pin (the polling workflow does both edits in one PR; Dependabot only edits the Dockerfile, so the operator must also bump the compose tag manually if it's a base-image bump).
3. **Smoke-test in a side-by-side container** before merging:
   ```bash
   docker build -t heimdall-caddy:test Heimdall/caddy/image
   docker run --rm heimdall-caddy:test caddy version
   docker run --rm heimdall-caddy:test caddy list-modules | grep layer4
   ```
4. **Merge** when satisfied. The build workflow publishes the new tag to GHCR; Heimdall pulls via Komodo or `docker compose pull`.

## Why this image is needed

The `caddy-l4` plugin is not part of the official Caddy distribution. The only ways to include it are:
- Build Caddy from source with `xcaddy --with` (this Dockerfile's approach).
- Use the Caddy "modules" download endpoint at runtime (rejected — runtime dependency on caddyserver.com).

This image is therefore the minimum custom artifact required by Heimdall's stack. Every other container Heimdall runs is an unmodified upstream image pulled from Docker Hub or GHCR.

## Komodo image versioning

Komodo (Core + Periphery) is upstream-only and not built from this directory. Komodo's `:2.2.0` pin is intentional (no floating `:2`); a future `.github/workflows/poll-komodo-releases.yml` will mirror the caddy-l4 polling pattern when Komodo v2.x bumps need automated PR surfacing.
