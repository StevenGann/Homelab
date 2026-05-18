# Fallback — HAProxy 3.2 for L4 traffic

> **Status:** documented fallback, **not active in v1**. This runbook exists so that
> if the `caddy-l4` plugin ever becomes unmaintainable (CVE, project archived,
> schema-breaking release we can't keep up with), there is a tested path to swap
> in HAProxy 3.2-alpine for the L4 (game-server / non-HTTP) traffic without
> changing the rest of the Heimdall stack.

## When to invoke this fallback

- `caddy-l4` upstream archived / unmaintained for > 6 months.
- A CVE in `caddy-l4` that the maintainer doesn't patch within 30 days.
- A `caddy-l4` schema change that breaks Heimdall's L4 routes between releases AND the previous version is no longer reachable through the polling-workflow auto-PR.

None of these are v1 concerns.

## What changes when fallback is invoked

The HTTPS proxy responsibilities (Caddy v2.11.3 + `tls internal` + `reverse_proxy`) stay with Caddy. Only the L4 (Minecraft TCP/UDP, future SFTP, etc.) moves to HAProxy.

### Compose stack — add HAProxy service

```yaml
  # Add to Heimdall/docker-compose.yml:
  haproxy:
    image: haproxy:3.2-alpine
    restart: unless-stopped
    network_mode: host           # need accurate source IPs for stick-tables
    volumes:
      - /opt/Homelab/Heimdall/haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    logging:
      driver: journald
```

### Caddyfile — remove L4 stanzas

Strip the `layer4 { ... }` global block from `Heimdall/caddy/Caddyfile`. Caddy reverts to HTTPS-only. Rebuild the Caddy image without `caddy-l4`:

```dockerfile
# Heimdall/caddy/image/Dockerfile becomes:
FROM caddy:2.11.3
# No xcaddy --with line. Use the official image directly.
```

The image tag changes from `homelab-heimdall-caddy:v2.11.3-l4-0.1.1` to a plain `homelab-heimdall-caddy:v2.11.3` (or just `caddy:2.11.3` upstream — at this point we're not customizing anymore).

### HAProxy config — `Heimdall/haproxy/haproxy.cfg`

```haproxy
global
    log /dev/log local0
    maxconn 4096

defaults
    log global
    timeout connect 5s
    timeout client  60s
    timeout server  60s

# Minecraft (TCP) — single backend
frontend mc_tcp_25565
    bind *:25565
    mode tcp
    default_backend mc_backend

backend mc_backend
    mode tcp
    server minecraft 192.168.10.247:25565 check

# Minecraft Bedrock (UDP) — UDP support landed in HAProxy 2.6+
# (For the cluster-internal MC server's IP, replace .247 with the actual host.)

# Add per-game-server frontend/backend pairs here as needed.
```

HAProxy is `network_mode: host`, so it binds the ports directly on Heimdall and sees real LAN client IPs. nftables already permits 25565/tcp+udp.

### nftables — no change

The ports were already open for `caddy-l4`. They stay open for HAProxy.

### UCG port-forwards — no change

Already forwarding 25565/tcp+udp → `192.168.10.240`. Continues to work.

## FTP (the protocol-level note)

If a future deployment ever needs to expose plain FTP (NOT SFTP — see the v1 plan's "FTP struck" rationale), HAProxy handles it natively:

```haproxy
frontend ftp_control
    bind *:21
    mode tcp
    default_backend ftp_backend

frontend ftp_passive
    bind *:50000-50100
    mode tcp
    default_backend ftp_backend

backend ftp_backend
    mode tcp
    stick-table type ip size 100k expire 1h
    stick on src                  # keep client pinned to one backend for control+data
    server ftp 192.168.10.247:21 check
```

The FTP server itself must be configured with:
- `pasv_address = <Heimdall's external WAN IP>` (so its PASV `227` response points back at Heimdall)
- `pasv_min_port = 50000`, `pasv_max_port = 50100`

UCG must forward 21/tcp and 50000-50100/tcp from WAN to `192.168.10.240`.

Also add an nftables ruleset entry on Heimdall for the PASV range:

```nftables
# In Heimdall/hostconf/nftables.conf (would need re-applied):
tcp dport 21 accept
tcp dport 50000-50100 accept
```

Don't enable any of this unless you actually need plain FTP. SFTP-via-port-22 is the modern answer.

## Rollback from HAProxy back to caddy-l4

If `caddy-l4` becomes maintainable again, the rollback is symmetric:

1. Rebuild the Caddy image with `--with github.com/mholt/caddy-l4@<current>`.
2. Add the `layer4 { ... }` stanzas back to the Caddyfile.
3. Remove the `haproxy` service from `docker-compose.yml`.
4. Run `docker compose up -d` — Compose recreates only the changed services.

## References

- HAProxy 3.2 release: <https://www.haproxy.org/news.html>
- HAProxy passive-FTP recipe (official tutorial): <https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/passive-ftp/>
- The pipeline-run iter-1 §C1 / §D.4 documents the team's reasoning for picking `caddy-l4` over HAProxy in v1.
