#!/usr/bin/env bash
set -euo pipefail

# migrate-tdarr-nfs-to-localpath.sh — copy Tdarr NeDB from Akasha NFS to
# node-local local-path PVC.
#
# This script completes the storage migration that commit d52c521 started:
# it copies the Tdarr database from the old Akasha NFS export to the new
# node-local local-path PVC (tdarr-server-data), then ensures the deployment
# references the new PVC.
#
# Usage:
#   ./migrate-tdarr-nfs-to-localpath.sh [--force]
#
# Options:
#   --force    Skip confirmation prompts (non-interactive mode).

NAMESPACE="media"
DEPLOYMENT="tdarr"
NEW_PVC="tdarr-server-data"
OLD_PVC="tdarr-server"
OLD_PV="akasha-app-media-tdarr-server"
NFS_SERVER="192.168.10.247"
NFS_PATH="/mnt/Media-Storage/Application-Storage/media/tdarr-server"
COPY_JOB="tdarr-nfs-migrate"
TEMP_PV="tdarr-nfs-migrate-pv"
TEMP_PVC="tdarr-nfs-migrate-pvc"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then FORCE=true; fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "FATAL: $*"; exit 1; }
warn() { log "WARN: $*"; }

# ─── preflight ────────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE not found"
kubectl get pvc "$NEW_PVC" -n "$NAMESPACE" >/dev/null 2>&1 || die "PVC $NEW_PVC not found — commit d52c521 must be applied first"

log "=== Tdarr NFS -> local-path migration ==="
log "Source:      Akasha NFS $NFS_SERVER:$NFS_PATH"
log "Destination: PVC $NEW_PVC (local-path, node-local)"

# ─── check current state ──────────────────────────────────────────────────────
CURRENT_CLAIM=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="server")].persistentVolumeClaim.claimName}' 2>/dev/null || echo "")
POD_NAME=$(kubectl get pod -l app=tdarr -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
POD_PHASE=$(kubectl get pod -l app=tdarr -n "$NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

log "Current deployment volume ref: ${CURRENT_CLAIM:-<none>}"
log "Current pod: ${POD_NAME:-<none>}  phase: ${POD_PHASE:-<none>}"

if [[ "$CURRENT_CLAIM" == "$NEW_PVC" ]] && [[ "$POD_PHASE" == "Running" ]]; then
  warn "Deployment already references $NEW_PVC and pod is Running."
  warn "If the service is healthy, the migration may already be complete."
  warn "To force re-run, delete the deployment pod first."
  exit 0
fi

# ─── determine NFS source ─────────────────────────────────────────────────────
NFS_SOURCE_TYPE=""
SRC_PVC=""

if kubectl get pvc "$OLD_PVC" -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Old PVC $OLD_PVC exists — using as source."
  NFS_SOURCE_TYPE="existing-pvc"
  SRC_PVC="$OLD_PVC"
elif kubectl get pv "$OLD_PV" >/dev/null 2>&1; then
  log "Old PV $OLD_PV exists but PVC gone — creating temp PVC bound to it."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $TEMP_PVC
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: $OLD_PV
  resources: { requests: { storage: 5Gi } }
EOF
  NFS_SOURCE_TYPE="temp-pvc"
  SRC_PVC="$TEMP_PVC"
else
  log "Old PV $OLD_PV not found — creating temp PV+PVC to mount NFS directly."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $TEMP_PV
spec:
  capacity: { storage: 5Gi }
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  mountOptions: [nfsvers=4.1, soft, timeo=100, retrans=2, noatime]
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
  resources: { requests: { storage: 5Gi } }
EOF
  NFS_SOURCE_TYPE="temp-pvc"
  SRC_PVC="$TEMP_PVC"
fi

# ─── confirm ──────────────────────────────────────────────────────────────────
if ! $FORCE; then
  echo ""
  echo "This will:"
  echo "  1. Scale deployment $DEPLOYMENT to 0 (stop the server)"
  echo "  2. Ensure deployment references $NEW_PVC"
  echo "  3. Copy NFS data -> local-path PVC ($NEW_PVC)"
  echo "  4. Scale deployment back to 1"
  echo ""
  read -r -p "Proceed? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    die "Aborted."
  fi
fi

# ─── step 1: scale down ───────────────────────────────────────────────────────
log "Step 1/4: Scaling deployment $DEPLOYMENT to 0..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
kubectl wait --for=delete pod -l app=tdarr -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
sleep 3
log "Deployment scaled down."

# ─── step 2: update deployment volume ref ─────────────────────────────────────
log "Step 2/4: Ensuring deployment references $NEW_PVC..."
if [[ "$CURRENT_CLAIM" != "$NEW_PVC" ]]; then
  log "Patching deployment: server volume claimName $CURRENT_CLAIM -> $NEW_PVC"
  kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json \
    -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName\", \"value\": \"$NEW_PVC\"}]"
else
  log "Deployment already references $NEW_PVC."
fi

# ─── step 3: copy data ────────────────────────────────────────────────────────
log "Step 3/4: Copying data: $SRC_PVC (NFS) -> $NEW_PVC (local-path)..."

kubectl apply -f - <<EOF
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
      command:
        - sh
        - -c
        - |
          set -e
          echo "Source ($SRC_PVC) contents:"
          ls -la /src/ || true
          echo ""
          echo "Destination ($NEW_PVC) contents before copy:"
          ls -la /dest/ || true
          echo ""
          if [ "$(ls -A /src/ 2>/dev/null)" ]; then
            echo "Copying NFS data to local-path PVC..."
            cp -a /src/. /dest/
            echo "Copy complete. Destination contents:"
            ls -la /dest/
          else
            echo "ERROR: No data found on source PVC."
            echo "Source listing:"
            find /src -maxdepth 3 -type f 2>/dev/null | head -50 || echo "(empty or error)"
            exit 1
          fi
      volumeMounts:
        - { name: src,  mountPath: /src }
        - { name: dest, mountPath: /dest }
  volumes:
    - { name: src,  persistentVolumeClaim: { claimName: "$SRC_PVC" } }
    - { name: dest, persistentVolumeClaim: { claimName: "$NEW_PVC" } }
EOF

log "Waiting for copy job to complete (timeout 300s)..."
if kubectl wait --for=condition=complete "pod/$COPY_JOB" -n "$NAMESPACE" --timeout=300s 2>/dev/null; then
  log "Copy job completed."
else
  log "Copy job failed — dumping logs:"
  kubectl logs "pod/$COPY_JOB" -n "$NAMESPACE" || true
  kubectl delete pod "$COPY_JOB" -n "$NAMESPACE" --ignore-not-found
  die "Copy failed. See logs above."
fi

kubectl logs "pod/$COPY_JOB" -n "$NAMESPACE"
kubectl delete pod "$COPY_JOB" -n "$NAMESPACE"

# ─── cleanup temporary PVCs ────────────────────────────────────────────────────
if [[ "$NFS_SOURCE_TYPE" == "temp-pvc" ]]; then
  log "Cleaning up temporary PVC $TEMP_PVC..."
  kubectl delete pvc "$TEMP_PVC" -n "$NAMESPACE" --ignore-not-found
  kubectl delete pv "$TEMP_PV" --ignore-not-found 2>/dev/null || true
fi

# ─── step 4: scale up ─────────────────────────────────────────────────────────
log "Step 4/4: Scaling deployment $DEPLOYMENT back to 1..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1

log "Waiting for pod Ready (timeout 600s)..."
if kubectl wait --for=condition=ready pod -l app=tdarr -n "$NAMESPACE" --timeout=600s 2>/dev/null; then
  log ""
  log "=== Migration complete ==="
  log "Deployment volume: $(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="server")].persistentVolumeClaim.claimName}')"
  NEW_POD=$(kubectl get pod -l app=tdarr -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
  log "Pod: $NEW_POD  $(kubectl get pod "$NEW_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
  log "Endpoint: http://192.168.10.62:8265"
  log ""
  log "The NeDB is now on node-local storage (/mnt/node-storage)."
  log "Old NFS copy preserved at $NFS_SERVER:$NFS_PATH as cold backup."
else
  warn "Pod did not become ready within 600s."
  kubectl describe pod -l app=tdarr -n "$NAMESPACE" | tail -50
  die "Startup failed. See describe output above."
fi
