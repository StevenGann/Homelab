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
| 2026-07-13 | qbittorrent2 / .83 | 85.8% of 6Gi | 15d | Re-applied httpGet liveness (regressed to tcpSocket in 6d3e7ed) |

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

## Pattern 4: tcpSocket Liveness Regression — AuthSubnetWhitelist Race

**First observed:** 2026-07-10~13, qbittorrent2 / .83 (15-day uptime, pod started Jun 28)

### Symptoms
- Pod `Running` 2/2, `Ready` True, but service DOWN via external watchdog
- Readiness probe (`httpGet /api/v2/app/version`) detected the hang and removed endpoints
- Liveness probe (`tcpSocket :8085`) remained green — port stayed LISTEN even though HTTP accept loop was deadlocked
- Pod survived 15 days with a hung HTTP server; no auto-restart occurred
- Zero application log output during the hang window (confirms process was truly frozen)
- Memory at 85.8% of 6Gi cgroup limit (RSS 4.4GB), elevated but not OOM
- Correlated: qBittorrent A had same readiness timeout ~30 minutes prior but self-recovered

### Root Cause

**Primary:** tcpSocket liveness probe was a regression. The `6d3e7ed` commit (2026-06-25) had reverted liveness from httpGet back to tcpSocket because httpGet liveness was killing containers during slow startup — the AuthSubnetWhitelist wasn't applied in time for the kubelet's httpGet probes to get 200 responses. The fix was an overcorrection: instead of fixing the AuthSubnetWhitelist race, it abandoned httpGet liveness entirely, leaving a blind spot for runtime HTTP hangs.

**Secondary (race condition):** The port-sync custom service applied AuthSubnetWhitelist via API only AFTER waiting for both the forwarded_port file (up to 120s) AND WebUI readiness (up to 5 min). This delay meant that on a fresh boot, the kubelet's httpGet probes targeting `/api/v2/app/version` would get 403 responses during the window between WebUI bind and whitelist API application. The `6d3e7ed` commit's response — using tcpSocket liveness — sidestepped this problem at the cost of losing runtime hang detection entirely.

**Tertiary (trigger):** Memory pressure at 85.8% (GC thrash near ceiling) likely caused the HTTP accept loop to deadlock, similar to the 2026-06-24 incident. The process hung but the TCP socket remained LISTEN, so tcpSocket liveness never fired.

### Prevention (IaC)

**Liveness probe — always httpGet on HTTP services:**
```yaml
livenessProbe:
  httpGet:
    path: /api/v2/app/version   # requires app logic, not static login page
    port: 8085
  initialDelaySeconds: 180
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

**Port-sync script — apply AuthSubnetWhitelist as early as possible:**
Swap the wait order so AuthSubnetWhitelist is applied via API immediately after WebUI is confirmed ready, BEFORE waiting for the forwarded_port file. This closes the race window where httpGet probes fire before the whitelist is active.

```sh
# WebUI wait first → set whitelist immediately → then wait for forwarded_port
until webui_ready; do ...; done
set_auth_subnet_whitelist_via_api   # <-- MOVED HERE
wait_for_forwarded_port             # <-- was here before
```

**Probe path selection — use an API endpoint, not a static asset:**
- `/` (login page): served by a static handler, may succeed even when app is hung
- `/api/v2/app/version`: requires the application's request router + auth layer, will fail if the accept loop is deadlocked

### Recovered Instances

| Date | Service | Liveness Type | Uptime | Fix Applied |
|------|---------|--------------|--------|-------------|
| 2026-07-13 | qbittorrent2 / .83 | tcpSocket (regression from 6d3e7ed) | 15 days | httpGet /api/v2/app/version + port-sync reorder |
| 2026-07-13 | qbittorrent / .58 | tcpSocket (same regression) | N/A | Same fix pre-emptively |
| 2026-07-13 | qbittorrent3 / .84 | tcpSocket (same regression) | N/A | Same fix pre-emptively |

### Lessons
1. Never use tcpSocket for liveness on an HTTP service — it is blind to HTTP-level hangs.
2. When a httpGet liveness probe fails during startup, fix the RACE (timing/ordering) rather than downgrading the probe type.
3. Auth bypass setup (whitelist, credentials) must complete BEFORE any httpGet probe can fire. In multi-step init scripts, ensure auth configuration runs as early as possible in the sequence, not after unrelated waits.

---

## Pattern 5: Readiness Probe on Aggregated-Dependency Endpoint Cascades to Service DOWN

**First observed:** 2026-07-15, Cleanuparr / .59 (19-day uptime)

### Symptoms
- Service pod is `Running` 1/1, but the LoadBalancer endpoint reports `Connection Refused`
- MetalLB Service shows `nodeAssigned` event on a delay (~4 min after readiness recovers)
- Internally, the pod's `/health` returns 200, but `/health/ready` returns 503
- Readiness probe (`httpGet /health/ready`) fails with statuscode 503 → endpoints dropped
- The root cause is a DEPENDENT service's transient failure, not the primary service itself
- Service self-recovers when the dependent service recovers (no restart needed), but the ~4 min endpoint re-announce gap causes a noticeable outage window

### Root Cause

Some applications expose a `/health/ready` endpoint that aggregates the health of ALL downstream dependencies (download clients, databases, etc.). When ANY single dependency is degraded — even a non-primary one — the readiness endpoint returns 503. This triggers k8s readiness probe failure → endpoints removed from the Service → MetalLB stops routing traffic → service is DOWN from the outside.

The cascade looks like:
1. Infrastructure blip (NFS/DNS/VPN) → downstream client (qBittorrent B) gets unhealthy
2. Cleanuparr `/health/ready` returns 503 because B is Degraded
3. Readiness probe fails → endpoints dropped (75s window: 5×15s)
4. MetalLB route withdrawn → `192.168.10.59:11011` unreachable (~4 min re-announce gap)

The dependency client (qBittorrent B) self-recovers, Cleanuparr's `/health/ready` returns 200, but the Service endpoint re-announcement takes several minutes.

### Prevention (IaC)

**Use `/health` for readiness, not `/health/ready`:**
```yaml
# DO: /health returns 200 even when download_clients subsystem is Degraded.
#    A single non-primary client degradation should NOT kill routing.
readinessProbe:
  httpGet: { path: /health, port: 11011 }
  periodSeconds: 15
  timeoutSeconds: 15
  failureThreshold: 5
```

**Keep `/health/ready` for watchdog monitoring:**
The watchdog (`homelab-watchdog.py`) should continue to monitor `/health/ready` — that's its job. But the k8s readiness probe must not use it.

**If `/health` also fails during Degraded state (application bug):**
Consider adding a dedicated liveness-only endpoint or relying on the external watchdog for dependency-health monitoring, keeping k8s probes scoped to the application's own internal health.

### Recovered Instances

| Date | Service | Probe Path | Dependency | Outage | Fix Applied |
|------|---------|-----------|------------|--------|-------------|
| 2026-07-15 | cleanuparr / .59 | /health → /health/ready | qbittorrent2 | ~9 min | Readiness probe switched to /health |
| 2026-07-15 | qbittorrent2 / .83 | tcpSocket liveness | (primary cause) | ~5 min | httpGet / + whitelist reorder |

### Interaction with Other Patterns

This pattern compounds with Pattern 1 (tcpSocket blind spot) and Pattern 4 (liveness regression): the dependency client's own liveness probe was blind to its HTTP hang, so it couldn't self-restart. Cleanuparr (correctly) detected the degraded client and (incorrectly) cascaded that into its own readiness failure.

### Lessons
1. Readiness probes should answer "is THIS service ready to accept traffic?" — not "are ALL downstream services healthy?"
2. If the application exposes both `/health` (internal-only) and `/health/ready` (with dependencies), use `/health` for k8s readiness and `/health/ready` only for external monitoring.
3. When a service goes DOWN from a readiness cascade, check its PROBE PATH first — it may be aggregating downstream health.

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
