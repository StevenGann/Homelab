# Adding a route through Caddy

> This is the Phase-3 reference for adding a new service to Heimdall's routing layer.
> Patterns differ for HTTP services on the k3s cluster vs. non-HTTP/L4 (game servers,
> SFTP, etc.).

## The two patterns

### Pattern A — HTTP service on the k3s cluster

For any service exposed by k3s as `type: NodePort`, Caddy fans out to **every Pi node's** IP on the assigned NodePort. Active health checks drop sick nodes automatically.

Three coordinated edits per service:

1. **k8s Service manifest** (e.g., `Hyperion/k8s/apps/my-service.yaml`):
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: my-service
     namespace: default
   spec:
     type: NodePort
     selector:
       app: my-service
     ports:
       - port: 8080
         targetPort: 8080
         nodePort: 30100      # operator-assigned; see allocation table below
   ```

2. **Caddyfile block** in `Heimdall/caddy/Caddyfile`:
   ```caddy
   my-service.lab {
       tls internal

       reverse_proxy 192.168.10.101:30100 192.168.10.102:30100 192.168.10.103:30100 \
                     192.168.10.104:30100 192.168.10.105:30100 192.168.10.106:30100 \
                     192.168.10.107:30100 192.168.10.108:30100 192.168.10.109:30100 \
                     192.168.10.110:30100 {
           lb_policy least_conn
           health_uri /healthz       # verify the service actually exposes this path
           health_interval 30s
           fail_duration 60s
       }
   }
   ```

3. **NodePort allocation table** entry in `Hyperion/docs/network-layout.md` (so the next operator doesn't pick the same port for a different service).

4. **DNS record** in `Heimdall/scripts/seed-zones.sh` `RECORDS=()`:
   ```bash
   RECORDS=(
       # ...existing entries...
       "my-service.lab|A|192.168.10.4"
   )
   ```

   Then run `bash /opt/Homelab/Heimdall/scripts/seed-zones.sh`.

5. (Optional) UCG WAN port-forward — only if the service should be reachable from the public internet. Add a forward on port 443 → `192.168.10.4` if not already present; the Caddyfile's `my-service.lab` block handles the rest.

After all edits land in `main`, on Heimdall:
```bash
cd /opt/Homelab/Heimdall
git pull
# Caddy hot-reloads the Caddyfile on save (via the volume mount + container's
# inotify watcher). If it doesn't, force:
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Pattern B — Non-HTTP / L4 (game servers, SFTP, etc.)

For non-HTTP traffic (Minecraft TCP/UDP, RCON, plain SFTP), use the `caddy-l4` plugin's `layer4` directive. Game servers typically run as **non-k8s containers** (per the approved plan §2.E — game ports are outside the NodePort range; keeping them non-k8s avoids the `--service-node-port-range` extension trap).

Caddyfile pattern (assumes Caddy v2.11.3 + caddy-l4 v0.1.1 Caddyfile syntax):

```caddy
{
    layer4 {
        :25565 {
            @minecraft tls          # if Minecraft Velocity is doing TLS; usually no
            route @minecraft {
                proxy minecraft.lab:25565
            }
            # Default route: plain TCP
            route {
                proxy minecraft.lab:25565
            }
        }
        :25565/udp {
            route {
                proxy udp/minecraft.lab:19132
            }
        }
    }
}
```

If the Caddyfile L4 syntax doesn't stabilize for your pinned `caddy-l4` version,
use the JSON form via a separate `Heimdall/caddy/layer4.json` and import via the
Caddyfile's `import` directive. Check the `caddy-l4` README for current syntax.

NodePort allocation does NOT apply to L4 game traffic — the `proxy` upstream is the game server's actual IP:port (typically a non-k8s container running on Monolith or Heimdall itself), not a NodePort fanout.

DNS still needs a `<game>.lab` record if the game-server admin tool addresses it by name. Add via `seed-zones.sh`.

## NodePort allocation policy

The NodePort range is `30000-32767` (k3s default). Suggested allocation convention:

| Range | Use |
|-------|-----|
| `30001-30099` | Reserved for ad-hoc / experimental services |
| `30100-30999` | Production HTTP services on the cluster (one port per service) |
| `31000-31999` | Production L4 services on the cluster (NOT game servers) |
| `32000-32767` | Reserved |

Per-service NodePort assignments live in `Hyperion/docs/network-layout.md`'s allocation table. **Two services must not share a NodePort.** A merge that introduces a conflict will be caught by k3s at Service-create time (it rejects the second one), but only after merge — preventive review is the operator's job.

## Sanity checks after adding a route

```bash
# DNS resolves
dig @192.168.10.4 my-service.lab
# → 192.168.10.4

# Caddy is serving (from LAN client with CA root trusted)
curl -sk https://my-service.lab/healthz
# → 200 (or whatever the service returns)

# Caddy's view of the upstream pool
docker compose exec caddy caddy adapt --config /etc/caddy/Caddyfile | jq '.. | objects | select(.handler == "reverse_proxy")? | .upstreams'
# → array of {dial: "192.168.10.101:30100"} etc.

# Health-check status (Caddy's admin endpoint, localhost-only inside the container)
docker compose exec caddy curl -s http://localhost:2019/reverse_proxy/upstreams
# → list of upstreams with `healthy: true/false`
```

## Troubleshooting

- **`curl https://my-service.lab` returns 502.** Caddy sees all upstreams as down. Either (a) the Service isn't yet created on the cluster, (b) the NodePort doesn't match what's in the Caddyfile, (c) the pod isn't ready, or (d) the `health_uri` path is wrong.
- **`curl` works from LAN but not from WAN.** Check the UCG port-forward for 443 → `.4` exists, and the WAN-side firewall isn't blocking the request before it reaches the UCG.
- **`docker compose exec caddy caddy reload` fails.** Caddyfile syntax error. `docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile` shows the line.
