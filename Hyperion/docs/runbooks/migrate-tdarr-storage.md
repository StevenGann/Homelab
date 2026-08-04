# Migrate Tdarr storage from NFS to local-path

## Context

Commit `d52c521` (2026-07-13) migrated the Tdarr NeDB database from Akasha NFS
to a node-local `local-path` PVC (`tdarr-server-data`). The change updated the
git IaC but requires a manual data migration step — copying the existing NeDB
files from the old NFS export to the new local-path PVC.

Without this migration, Tdarr starts with an empty database (losing all library
configurations, transcode history, and node registrations). The old NFS data at
`192.168.10.247:/mnt/Media-Storage/Application-Storage/media/tdarr-server` is
preserved as a cold backup.

## Symptoms

- Watchdog reports `Errno 111 Connection refused` for `http://192.168.10.62:8265`
- Pod cycles through startup probe failures (corrupted NeDB from NFS I/O stall)
- `kubectl get pvc -n media tdarr-server-data` shows the PVC exists but has no data
- `kubectl get deployment tdarr -n media -o jsonpath='{.spec.template.spec.volumes[?(@.name=="server")].persistentVolumeClaim.claimName}'` returns `tdarr-server` (old NFS PVC) instead of `tdarr-server-data`

## Procedure

### Automated migration (preferred)

```bash
cd Hyperion/k8s/scripts
./migrate-tdarr-nfs-to-localpath.sh [--force]
```

The script handles all three cluster-state scenarios:
1. Old `tdarr-server` PVC still exists → mounts it directly as source
2. Old `akasha-app-media-tdarr-server` PV exists but PVC gone → creates temp PVC bound to it
3. Neither exist → creates temp PV+PVC mounting the NFS export directly

### Manual migration

If the script cannot run for any reason:

```bash
# 1. Scale down
kubectl scale deployment tdarr -n media --replicas=0
kubectl wait --for=delete pod -l app=tdarr -n media --timeout=120s

# 2. Ensure deployment references the new PVC
kubectl patch deployment tdarr -n media --type=json -p='[{
  "op": "replace",
  "path": "/spec/template/spec/volumes/0/persistentVolumeClaim/claimName",
  "value": "tdarr-server-data"
}]'

# 3. Create a copy pod (adjust source PVC name if old PVC still exists)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: tdarr-nfs-migrate
  namespace: media
spec:
  nodeSelector: { topology.kubernetes.io/zone: hyperion }
  restartPolicy: Never
  containers:
    - name: copier
      image: busybox:stable
      command: ["sh", "-c", "cp -a /src/. /dest/ && ls -la /dest/"]
      volumeMounts:
        - { name: src,  mountPath: /src }
        - { name: dest, mountPath: /dest }
  volumes:
    - { name: src,  persistentVolumeClaim: { claimName: tdarr-server } }
    - { name: dest, persistentVolumeClaim: { claimName: tdarr-server-data } }
EOF

kubectl wait --for=condition=complete pod/tdarr-nfs-migrate -n media --timeout=300s
kubectl logs pod/tdarr-nfs-migrate -n media
kubectl delete pod tdarr-nfs-migrate -n media

# 4. Scale up
kubectl scale deployment tdarr -n media --replicas=1
kubectl wait --for=condition=ready pod -l app=tdarr -n media --timeout=600s
```

### Verification

```bash
# Confirm the deployment volume ref
kubectl get deployment tdarr -n media -o jsonpath='{.spec.template.spec.volumes[?(@.name=="server")].persistentVolumeClaim.claimName}'
# Expected: tdarr-server-data

# Confirm the pod is running and the endpoint responds
curl -s -o /dev/null -w '%{http_code}' http://192.168.10.62:8265
# Expected: 200

# Confirm the NeDB is on local storage (not NFS)
kubectl exec -n media deploy/tdarr -- df -h /app/server | grep -v "^Filesystem"
# Expected: /dev/nvme0n1pX (local NVMe), not 192.168.10.247 (NFS)
```

## Post-migration

- The old NFS PV `akasha-app-media-tdarr-server` and PVC `tdarr-server` can be
  pruned after confirming the migration is successful and the service has been
  stable for 48+ hours. The Akasha NFS data at the export path is preserved
  independently (Retain reclaim policy).
- The `tdarr-server-data` PVC is pinned to whichever Hyperion node first
  provisioned it. If that node is replaced, the data must be migrated off before
  decommissioning the node. See ADR-0003 for the Longhorn migration plan.

## Related

- ADR-0003: `docs/design/adr-0003-longhorn-deferred.md` — NFS death spiral
  diagnosis and Longhorn migration plan
- Radarr NFS probe fix: `Hyperion/k8s/apps/media/10-core/radarr/deployment.yaml`
  — identical tcpSocket probe pattern (2026-06-06)
- Migration script: `Hyperion/k8s/scripts/migrate-tdarr-nfs-to-localpath.sh`
