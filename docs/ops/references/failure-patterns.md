# Homelab Failure Patterns

Catalog of recurring failure modes observed in the homelab, their root causes,
detection signals, and prevention strategies. Each pattern describes a
production incident that was diagnosed and permanently fixed.

---

## Pattern 1: tcpSocket Probe Blind Spot

**First observed:** 2026-06-24, qbittorrent2 / .83 (18h uptime)
**Service type:** Any application with an HTTP WebUI/API that can hang
independently of its TCP listen socket

### Symptoms
- Pod reports `Running` + `Ready` (2/2) but the service is DOWN
- HTTP endpoint returns 200 from a reverse-proxy decoy, or times out
- `kubectl get pod` shows "Ready" because the tcpSocket probe can open a
  TCP connection to the port — the kernel accepts the SYN
- Inside the pod: the port is LISTEN at TCP level (`ss -tlnp` shows it),
  but the HTTP accept loop is deadlocked — no HTTP responses are served
- No liveness probe → hung state persists indefinitely (no auto-restart)

### Root Cause
`readinessProbe.tcpSocket` only verifies that the kernel's TCP stack
accepts connections on the port. It cannot detect application-level
deadlocks in the HTTP server's accept loop. Common triggers:

1. **Near-ceiling memory pressure** (e.g., 99.88% of cgroup limit):
   - GC thrash consumes all CPU, starving the accept thread
   - malloc deadlock in a dependent library
   - The kernel still responds to TCP SYNs, so tcpSocket passes

2. **Thread pool exhaustion**: all worker threads blocked on
   long-running I/O, accept thread never gets CPU

3. **Internal deadlock** in the HTTP framework (e.g., mutex contention
   between the config reload handler and the request router)

### How to Detect
- **Active:** An HTTP-level readiness probe (`httpGet`) that hits an API
  endpoint requiring application logic (not just a static file)
- **Passive:** Watchdog external HTTP check (homelab-watchdog.py) that
  validates response status codes

### Prevention (IaC)
```yaml
# DO NOT use tcpSocket for readiness or liveness probes on HTTP services
readinessProbe:
  httpGet:
    path: /api/v2/app/version   # requires app logic, not just static
    port: 8085
  periodSeconds: 15
  failureThreshold: 3
livenessProbe:
  httpGet:
    path: /api/v2/app/version
    port: 8085
  initialDelaySeconds: 120      # long initial delay to avoid startup races
  periodSeconds: 30
  failureThreshold: 3
```

### tcpSocket Is Acceptable For
- **startupProbe** on slow-starting services (Pi 5 + NFS config +
  hundreds of torrents can take 10-20 minutes to bind the WebUI).
  A tcpSocket startup probe detects "port is bound" without triggering
  auth or API readiness checks prematurely. Once the startup phase
  passes, httpGet readiness/liveness probes take over.
- **Non-HTTP TCP services** (e.g., Mosquitto MQTT).

### Recovered Instances
| Date | Service | Memory % | Uptime | Fix Applied |
|------|---------|----------|--------|-------------|
| 2026-06-24 | qbittorrent2 / .83 | 99.88% of 4Gi | 18h | httpGet probes + 6Gi limit |
| 2026-06-24 | qbittorrent / .58 | N/A | N/A | Same fix pre-emptively |
| 2026-06-24 | qbittorrent3 / .84 | N/A | N/A | Same fix pre-emptively |

---

## Pattern 2: Flux Apply Failure on Probe Handler Type Replacement

**First observed:** 2026-06-25, during media-core reconciliation of commit
dff6869

### Symptoms
- Flux Kustomization reports `False` status
- Error: `"may not specify more than 1 handler type"`
- The deployment YAML in git is correct (e.g., only `httpGet`, no
  `tcpSocket`)
- But the running deployment still has the OLD handler type

### Root Cause
When changing a probe from one handler type to another (e.g.,
`tcpSocket` → `httpGet`), `kubectl apply` merges the new spec onto the
existing object. The API server sees BOTH old and new handler types on
the same probe and rejects it as invalid — a probe can only have one
handler type.

The `kubectl apply` three-way merge cannot "see" that the old handler
was removed in the new manifest; it only sees additions relative to the
`last-applied-configuration` annotation.

### Prevention
When changing a probe handler type, use a JSON patch (`kubectl patch
--type='json' -p='[{"op":"replace",...}]'`) instead of `kubectl apply`:

```bash
kubectl patch deployment -n media qbittorrent2 --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe",
   "value": {"httpGet": {"path": "/api/v2/app/version", "port": 8085},
             "initialDelaySeconds": 20, "periodSeconds": 15,
             "timeoutSeconds": 10, "failureThreshold": 3}}
]'
```

Alternatively, delete and recreate the deployment. Once the new handler
type is in place, future `kubectl apply` operations (including Flux
reconciliations) will succeed because the handler type matches.

### Managed via
This repository's IaC. The `kubectl patch` command above is the
supported path for future handler-type changes.

---

## Pattern 3: NFS-Backed Config Volume Causes Slow Pod Startup

**First observed:** 2026-06-25, all 3 qbittorrent instances after
adding startupProbe with httpGet

### Symptoms
- Pod is `Running` but `1/2 Ready` for >10 minutes
- startupProbe (httpGet) fails with `connection refused`
- Inside the container: `qbittorrent-nox` process is running (PID
  exists) but port 8085 is not yet in LISTEN state
- `/proc/net/tcp` shows the torrent port bound but NOT the WebUI port
- Process may be in `D` (disk sleep) state with high nonvoluntary
  context switch count

### Root Cause
On a Raspberry Pi 5, qbittorrent-nox with hundreds of torrents and an
NFS-mounted config directory (`/config` on Akasha NFS) takes 10-20
minutes to fully initialize before binding the WebUI port. During this
time, it's loading resume data, verifying torrents, and writing
state/logs — all over the NFS link.

The httpGet startup probe fires after 40s and expects the WebUI to
respond. On Pi 5 + NFS, this is physically impossible — the WebUI
port isn't even bound yet.

### Prevention
Use a `tcpSocket` startup probe with a generous 30-minute window for
services that:
- Run on resource-constrained nodes (Pi 5)
- Mount config/data over NFS
- Have long initialization that precedes binding the HTTP port

```yaml
startupProbe:
  tcpSocket: { port: 8085 }
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 180   # 30 minutes
```

The tcpSocket probe succeeds as soon as the process binds the port,
which is the earliest signal that initialization is complete. httpGet
readiness and liveness probes then take over to detect runtime hangs.

---

## Pattern Reference Table

| Pattern | Detectable by tcpSocket? | Detectable by httpGet? | Detectable by watchdog? |
|---------|--------------------------|------------------------|--------------------------|
| TCP port not bound (startup) | Yes | Yes (connection refused) | Connection error |
| HTTP accept loop deadlocked | **NO** (blind spot) | Yes (timeout/error) | Yes (timeout/error) |
| Memory-induced GC thrash | Sometimes (connect latency) | Yes (slow/timeout) | Yes (timeout) |
| Thread pool exhaustion | **NO** | Yes (timeout/error) | Yes (timeout) |
| Application logic error (5xx) | **NO** | Yes (non-2xx) | Yes (non-2xx) |
| Port bound but auth required | N/A | Yes (403/401) | Yes (403/401) |

**Conclusion:** Every HTTP-based service in this homelab MUST have
httpGet readiness and liveness probes. tcpSocket is only acceptable
for startup probes on slow-starting services, or for non-HTTP TCP
services.
