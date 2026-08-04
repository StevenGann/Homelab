#!/usr/bin/env bash
set -euo pipefail

# migrate-qbittorrent3-nfs-to-localpath.sh — copy qBittorrent3 (instance C)
# config from Akasha NFS to node-local local-path PVC to resolve the HTTP
# server hang incident (2026-07-17).
#
# qbittorrent-nox's Qt event loop blocks when NFS I/O stalls on hard NFS mount
# (process in Ssl state) → TCP port 8085 stays bound but HTTP server stops
# responding → httpGet probes return context deadline exceeded → liveness kill
# + restart loop.  Cross-node correlation with qbittorrent (also NFS) and
# qbittorrent2 (local-path, clean control) confirms NFS is the root cause.
#
# Instance #3 runs on hyperion-kappa (LA VPN exit, MetalLB .84).
#
# Usage:
#   ./migrate-qbittorrent3-nfs-to-localpath.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts (non-interactive mode).
#
# Cluster access: this script defaults to kubectl via the Heimdall control-plane
# container. Set KUBECTL_CMD to override.

NAMESPACE="media"
DEPLOYMENT="qbittorrent3"
APP_LABEL="app=qbittorrent3"
PVC_NAME="qbittorrent3-config"           # same name — downstream (deployment) needs no changes
OLD_PV="akasha-app-media-qbittorrent3-config"
NFS_SERVER="192.168.10.247"
NFS_PATH="/mnt/Media-Storage/Application-Storage/media/qbittorrent3-config"
COPY_JOB="qbittorrent3-nfs-migrate"
TEMP_PV="qbittorrent3-nfs-migrate-pv"
TEMP_PVC="qbittorrent3-nfs-migrate-pvc"
PVC_SIZE="5Gi"

KUBECTL_CMD="${KUBECTL_CMD:-ssh -o StrictHostKeyChecking=no owner@192.168.10.4 sudo docker exec -i k3s-control-plane-k3s-server-1 kubectl}"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then FORCE=true; fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }
warn() { log "WARN: $*"; }

# k: run a kubectl command (no stdin needed).
k()    { eval "$KUBECTL_CMD" "$@"; }

# ─── preflight ────────────────────────────────────────────────────────────────
k get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE not reachable"
k get deployment "$DEPLOYMENT" -n "$NAMESPACE" >/dev/null 2>&1 || die "deployment $DEPLOYMENT not found"

log "=== qBittorrent3 (C) NFS -> local-path migration ==="
log "Source:      Akasha NFS $NFS_SERVER:$NFS_PATH"
log "Destination: PVC $PVC_NAME (local-path, node-local)"
log ""

# ─── check current PVC state ──────────────────────────────────────────────────
CURRENT_STORAGECLASS=$(k get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
POD_NAME=$(k get pod -l "$APP_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
POD_READY=$(k get pod -l "$APP_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

log "Current PVC storageClassName: ${CURRENT_STORAGECLASS:-<none>}"
log "Current pod: ${POD_NAME:-<none>}  ready: ${POD_READY:-<none>}"

if [[ "$CURRENT_STORAGECLASS" == "local-path" ]] && [[ "$POD_READY" == "True" ]]; then
  warn "PVC $PVC_NAME is already local-path and pod is Ready."
  warn "Migration may already be complete."
  exit 0
fi

# ─── confirm ──────────────────────────────────────────────────────────────────
if ! $FORCE; then
  echo ""
  echo "This will:"
  echo "  1. Scale deployment $DEPLOYMENT to 0"
  echo "  2. Delete the old NFS PVC ($PVC_NAME) — preserves PV data on Akasha"
  echo "  3. Create a new local-path PVC ($PVC_NAME, $PVC_SIZE)"
  echo "  4. Mount Akasha NFS via a soft-mount temporary PV+PVC"
  echo "  5. Copy config data NFS -> local-path PVC"
  echo "  6. Scale deployment back to 1"
  echo "  7. Clean up temp resources and old NFS PV"
  echo ""
  echo "The old NFS data at $NFS_SERVER:$NFS_PATH is preserved as cold backup."
  echo ""
  read -r -p "Proceed? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    die "Aborted."
  fi
fi

# ─── step 1: scale down ───────────────────────────────────────────────────────
log "Step 1/7: Scaling deployment $DEPLOYMENT to 0..."
k scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
k wait --for=delete pod -l "$APP_LABEL" -n "$NAMESPACE" --timeout=60s 2>/dev/null || {
  warn "Pod did not terminate gracefully (NFS hang likely); force-deleting..."
  k delete pod -l "$APP_LABEL" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
  sleep 5
}
log "Deployment scaled down."

# ─── step 2: delete old NFS PVC ────────────────────────────────────────────────
#    PV has reclaimPolicy=Retain and the prune:disabled annotation, so the PV
#    survives but moves to "Released" — the NFS data on Akasha is untouched.
log "Step 2/7: Deleting old NFS PVC $PVC_NAME..."
if k get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  # Remove the finalizer so kubernetes.io/pvc-protection doesn't block
  k patch pvc "$PVC_NAME" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  k delete pvc "$PVC_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false
  # Wait for PVC to be gone
  for _ in $(seq 1 30); do
    if ! k get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  log "Old NFS PVC deleted."
else
  log "Old PVC already absent."
fi

# ─── step 3: create new local-path PVC ─────────────────────────────────────────
log "Step 3/7: Creating local-path PVC $PVC_NAME ($PVC_SIZE)..."
cat <<EOF | eval "$KUBECTL_CMD" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
  annotations: { kustomize.toolkit.fluxcd.io/prune: disabled }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: $PVC_SIZE } }
EOF
log "Local-path PVC created."

# ─── step 4: mount NFS via soft-mount temp PV+PVC for the copy ────────────────
log "Step 4/7: Creating temporary soft-mount NFS PV+PVC to access source data..."
cat <<EOF | eval "$KUBECTL_CMD" apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $TEMP_PV
spec:
  capacity: { storage: $PVC_SIZE }
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  mountOptions: [nfsvers=4.1, soft, timeo=50, retrans=2, noatime]
  nfs: { server: $NFS_SERVER, path: "$NFS_PATH" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $TEMP_PVC
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: $TEMP_PV
  resources: { requests: { storage: $PVC_SIZE } }
EOF
log "Temp PV+PVC created."

# ─── step 5: copy data (NFS temp PVC -> local-path PVC) ───────────────────────
log "Step 5/7: Copying data: $TEMP_PVC (soft NFS) -> $PVC_NAME (local-path)..."

cat <<EOF | eval "$KUBECTL_CMD" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $COPY_JOB
  namespace: $NAMESPACE
spec:
  nodeSelector: { topology.kubernetes.io/zone: hyperion }
  restartPolicy: Never
  containers:
    - name: copier
      image: busybox:stable
      securityContext:
        runAsUser: 568
        runAsGroup: 568
      command:
        - sh
        - -c
        - |
          set -e
          echo "Source ($TEMP_PVC / NFS) contents:"
          ls -la /src/ || true
          echo ""
          echo "Destination ($PVC_NAME / local-path) contents before copy:"
          ls -la /dest/ || true
          echo ""
          if [ "\$(ls -A /src/ 2>/dev/null)" ]; then
            echo "Copying NFS data to local-path PVC..."
            cp -av /src/. /dest/. 2>/dev/null || true
            # Verify the copy succeeded by checking file count on destination
            DEST_FILES=\$(find /dest -type f 2>/dev/null | wc -l)
            SRC_FILES=\$(find /src -type f 2>/dev/null | wc -l)
            echo "Copy complete."
            echo ""
            echo "Source file count: \$SRC_FILES"
            echo "Dest   file count: \$DEST_FILES"
            echo "Dest   size:       \$(du -sh /dest/ 2>/dev/null | cut -f1)"
            if [ "\$DEST_FILES" -eq 0 ] || [ "\$DEST_FILES" -lt "\$SRC_FILES" ]; then
              echo "ERROR: File count mismatch — copy failed."
              exit 1
            fi
          else
            echo "ERROR: No data found on source PVC."
            find /src -maxdepth 3 -type f 2>/dev/null | head -50 || echo "(empty or error)"
            exit 1
          fi
      volumeMounts:
        - { name: src,  mountPath: /src }
        - { name: dest, mountPath: /dest }
  volumes:
    - { name: src,  persistentVolumeClaim: { claimName: "$TEMP_PVC" } }
    - { name: dest, persistentVolumeClaim: { claimName: "$PVC_NAME" } }
EOF

log "Waiting for copy job to complete (timeout 900s)..."
if k wait --for=condition=complete "pod/$COPY_JOB" -n "$NAMESPACE" --timeout=900s 2>/dev/null; then
  log "Copy job completed."
else
  log "Copy job failed or timed out — dumping logs:"
  k logs "pod/$COPY_JOB" -n "$NAMESPACE" 2>/dev/null || true
  k delete pod "$COPY_JOB" -n "$NAMESPACE" --ignore-not-found
  die "Copy failed. Old NFS data and PV are preserved. Recreate the old PVC to roll back."
fi

k logs "pod/$COPY_JOB" -n "$NAMESPACE"
k delete pod "$COPY_JOB" -n "$NAMESPACE"

# ─── step 6: scale up ─────────────────────────────────────────────────────────
log "Step 6/7: Scaling deployment $DEPLOYMENT back to 1..."
k scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1

# The pod has a 30-min startup window (failureThreshold=180 × period=10s)
log "Waiting for pod Ready (timeout 1200s, startup probe allows 30 min)..."
if k wait --for=condition=ready pod -l "$APP_LABEL" -n "$NAMESPACE" --timeout=1200s 2>/dev/null; then
  log ""
  log "=== Pod is Ready ==="
else
  warn "Pod did not become ready within 1200s."
  k describe pod -l "$APP_LABEL" -n "$NAMESPACE" | tail -60
  warn "Old NFS data and PV are preserved. Recreate the old PVC to roll back."
  die "Startup failed."
fi

# ─── step 7: verify + cleanup ─────────────────────────────────────────────────
log "Step 7/7: Verifying app health and cleaning up..."

# Verify the PVC is now local-path
NEW_SC=$(k get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
if [[ "$NEW_SC" != "local-path" ]]; then
  warn "PVC $PVC_NAME storageClassName is $NEW_SC, expected local-path"
fi

# Verify API endpoint
POD=$(k get pod -l "$APP_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
log "Verifying qBittorrent API on pod $POD..."
if k exec -n "$NAMESPACE" "$POD" -c qbittorrent -- curl -sf http://127.0.0.1:8085/api/v2/app/version >/dev/null 2>&1; then
  log "API endpoint healthy: GET /api/v2/app/version -> 200 OK"
else
  warn "API endpoint not reachable yet. Logs:"
  k logs -n "$NAMESPACE" "$POD" -c qbittorrent --tail=20 2>/dev/null || true
fi

# Check endpoints registered
ENDPOINTS=$(k get endpoints -n "$NAMESPACE" qbittorrent3 -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
log "Service endpoints: ${ENDPOINTS:-<none yet>}"

# Cleanup temp NFS PV+PVC
log "Cleaning up temporary NFS PV+PVC..."
k delete pvc "$TEMP_PVC" -n "$NAMESPACE" --ignore-not-found
k delete pv "$TEMP_PV" --ignore-not-found 2>/dev/null || true

# Cleanup old NFS PV (now Released)
if k get pv "$OLD_PV" >/dev/null 2>&1; then
  log "Cleaning up old NFS PV $OLD_PV..."
  k patch pv "$OLD_PV" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  k delete pv "$OLD_PV" --ignore-not-found 2>/dev/null || true
fi

# ─── summary ───────────────────────────────────────────────────────────────────
log ""
log "=== Migration complete ==="
log "PVC:       $PVC_NAME ($(k get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}'))"
NEW_POD=$(k get pod -l "$APP_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
NODE=$(k get pod -l "$APP_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].spec.nodeName}')
log "Pod:       $NEW_POD  Node: $NODE  Phase: $(k get pod "$NEW_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
log "Endpoints: $(k get endpoints -n "$NAMESPACE" qbittorrent3 -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo '<none yet>')"
log "Service:   http://192.168.10.84:8085"
log ""
log "The config is now on node-local storage (/mnt/node-storage)."
log "Old NFS copy preserved at $NFS_SERVER:$NFS_PATH as cold backup."
