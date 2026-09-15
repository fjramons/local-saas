# --- Storage mode 'nfs' for 'saas cluster create --storage-mode nfs' (default StorageClass without nodeAffinity).

_saas_cluster_setup_storage_nfs() {
    local name="$1"
    local ctx="kind-${name}"

    _saas_log_step "Deploying an NFS server on '${name}'..."
    kubectl --context "$ctx" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: nfs-server}
  template:
    metadata:
      labels: {app: nfs-server}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${name}-control-plane
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nfs-server
          # Tag "12" is effectively "latest" today: this image has had no
          # release since 2019. Pinned explicitly (instead of "latest") so
          # a future re-push of "latest" by the maintainer can't silently
          # change --storage-mode nfs's behavior. See the "Pinned versions"
          # table in CLAUDE.md.
          image: itsthenetwork/nfs-server-alpine:12
          env:
            - {name: SHARED_DIRECTORY, value: /exports}
          volumeMounts:
            - {name: exports, mountPath: /exports}
          securityContext:
            privileged: true
          ports:
            - {containerPort: 2049, name: nfs}
      volumes:
        - name: exports
          hostPath:
            path: /mnt/nfs-exports
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: kube-system
spec:
  selector: {app: nfs-server}
  ports:
    - {port: 2049, name: nfs}
EOF
    kubectl --context "$ctx" -n kube-system rollout status --timeout=120s deployment/nfs-server \
        || { _saas_log_err "The NFS server didn't start in time."; return 1; }

    # "helm install --wait" prints nothing while waiting (unlike "rollout
    # status" used above for nfs-server); measured in practice this leaves
    # ~30s of total silence in the common case, up to 180s in the worst
    # case, hence the explicit message.
    _saas_log_step "Installing csi-driver-nfs via Helm (can take up to 3 min)..."
    timeout 30 helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts >/dev/null 2>&1
    timeout 30 helm repo update csi-driver-nfs >/dev/null 2>&1
    helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
        --kube-context "$ctx" -n kube-system --wait --timeout 180s \
        || { _saas_log_err "Failed to install csi-driver-nfs."; return 1; }

    kubectl --context "$ctx" apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.kube-system.svc.cluster.local
  share: /
reclaimPolicy: Delete
volumeBindingMode: Immediate
# 4.1 instead of 4.2: it's the protocol version most broadly supported by
# the lightweight NFS server used here (itsthenetwork/nfs-server-alpine,
# built on 2019-era tooling, no guarantee of full 4.2 support), and there's
# no local use case that needs 4.2-only features (e.g. server-side copy).
# Not exposed as a configurable flag, to avoid adding configuration surface
# with no real use case behind it.
mountOptions:
  - nfsvers=4.1
EOF

    kubectl --context "$ctx" patch storageclass standard \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
        >/dev/null 2>&1

    _saas_log_ok "StorageClass 'nfs-csi' set as default."
}
