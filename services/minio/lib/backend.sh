# --- The actual MinIO workload for 'saas minio': a standalone release, not GitLab's private
# datastore. --mode dev is a generalization of services/gitlab/lib/datastore.sh's single-instance
# MinIO Deployment (same image pin, same resource shape); --mode prod is a generalization of
# services/gitlab/lib/datastore.sh's _saas_gitlab_datastore_minio_ha_apply (same 4-node distributed
# StatefulSet, MinIO's own ellipsis server-pool syntax, no operator needed). Resources are named
# after THIS release directly (${release}/${release}-credentials), not '${release}-minio', since
# there's no parent release to namespace under any more.

# _saas_minio_secrets_apply NAMESPACE RELEASE ROOT_USER ROOT_PASSWORD
_saas_minio_secrets_apply() {
    local ns="$1" release="$2" root_user="$3" root_password="$4"

    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    kubectl -n "$ns" create secret generic "${release}-credentials" \
        --from-literal=rootUser="$root_user" --from-literal=rootPassword="$root_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
}

# _saas_minio_dev_apply NAMESPACE RELEASE STORAGE_CLASS ROOT_USER ROOT_PASSWORD
# --mode dev only (see _saas_minio_prod_apply for --mode prod).
_saas_minio_dev_apply() {
    local ns="$1" release="$2" storage_class="$3" root_user="$4" root_password="$5"

    local storage="5Gi" cpu="100m" mem="256Mi"

    # Two separate variables, not one reused at both indentation depths: this function emits
    # storageClassName at two structurally different nesting levels (a standalone PVC's spec vs. a
    # StatefulSet's volumeClaimTemplates[].spec in _saas_minio_prod_apply below), and YAML's
    # indentation is meaningful. See CLAUDE.md (services/gitlab/) for the real, live bug this
    # precedent exists to avoid: a single shared variable was correct at one site and silently
    # wrong at the other, never caught because --cluster-mode kind always leaves storage_class empty.
    local sc_field=""
    [ -n "$storage_class" ] && sc_field="  storageClassName: ${storage_class}"

    _saas_minio_secrets_apply "$ns" "$release" "$root_user" "$root_password" || return 1

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${release}
  labels: {app: ${release}}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${release}}
  template:
    metadata:
      labels: {app: ${release}}
    spec:
      containers:
        - name: minio
          image: ${_SAAS_MINIO_IMAGE}
          args: ["server", "/data", "--console-address", ":9001"]
          ports: [{containerPort: 9000}, {containerPort: 9001}]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootUser}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootPassword}}
          resources:
            requests: {cpu: ${cpu}, memory: ${mem}}
          volumeMounts:
            - {name: data, mountPath: /data}
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: ${release}-data}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${release}-data
spec:
  accessModes: [ReadWriteOnce]
${sc_field}
  resources: {requests: {storage: ${storage}}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}
  labels: {app: ${release}}
spec:
  selector: {app: ${release}}
  ports: [{name: api, port: 9000, targetPort: 9000}, {name: console, port: 9001, targetPort: 9001}]
EOF

    _saas_log_wait "Waiting for MinIO to be ready…"
    kubectl -n "$ns" rollout status deployment "${release}" --timeout=120s || return 1
    _saas_log_ok "MinIO ready (single instance)."
}

# _saas_minio_prod_apply NAMESPACE RELEASE STORAGE_CLASS ROOT_USER ROOT_PASSWORD
# --mode prod: 4-node distributed mode, MinIO's own clustering via its startup command, no operator
# needed (see services/gitlab/lib/datastore.sh's _saas_gitlab_datastore_minio_ha_apply, the origin
# of this exact shape). The normal ClusterIP Service '${release}' is kept identical to --mode dev
# (same name, selects all 4 pods) so every consumer stays unaware of whether MinIO is 1 or 4 nodes.
_saas_minio_prod_apply() {
    local ns="$1" release="$2" storage_class="$3" root_user="$4" root_password="$5"

    local storage="50Gi" cpu="500m" mem="1Gi"
    local sc_field=""
    [ -n "$storage_class" ] && sc_field="        storageClassName: ${storage_class}"

    # Three dots in '{0...3}' is required by MinIO's own ellipsis syntax for server pools. Two dots
    # gets shell-expanded locally by the container's entrypoint and breaks erasure-set ordering.
    local minio_endpoint="http://${release}-{0...3}.${release}-headless.${ns}.svc.cluster.local/data"

    _saas_minio_secrets_apply "$ns" "$release" "$root_user" "$root_password" || return 1

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: v1
kind: Service
metadata:
  name: ${release}-headless
  labels: {app: ${release}}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: {app: ${release}}
  ports: [{name: api, port: 9000, targetPort: 9000}]
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}
  labels: {app: ${release}}
spec:
  selector: {app: ${release}}
  ports: [{name: api, port: 9000, targetPort: 9000}, {name: console, port: 9001, targetPort: 9001}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${release}
  labels: {app: ${release}}
spec:
  serviceName: ${release}-headless
  replicas: 4
  selector:
    matchLabels: {app: ${release}}
  template:
    metadata:
      labels: {app: ${release}}
    spec:
      containers:
        - name: minio
          image: ${_SAAS_MINIO_IMAGE}
          args: ["server", "${minio_endpoint}", "--console-address", ":9001"]
          ports: [{containerPort: 9000}, {containerPort: 9001}]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootUser}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootPassword}}
          resources:
            requests: {cpu: ${cpu}, memory: ${mem}}
          volumeMounts:
            - {name: data, mountPath: /data}
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
${sc_field}
        resources: {requests: {storage: ${storage}}}
EOF

    _saas_log_wait "Waiting for the 4-node MinIO cluster to be ready…"
    kubectl -n "$ns" rollout status statefulset "${release}" --timeout=300s || return 1
    _saas_log_ok "MinIO ready (4-node distributed)."
}

# _saas_minio_init_buckets NAMESPACE RELEASE [BUCKET...]
# Ephemeral Job with the pinned mc image that (idempotently) pre-creates the given buckets, used at
# install time by --bucket (see install.sh). No-op if no bucket names are given.
_saas_minio_init_buckets() {
    local ns="$1" release="$2"; shift 2
    [ "$#" -eq 0 ] && return 0

    local mb_cmds="" bucket
    for bucket in "$@"; do
        mb_cmds+="mc mb --ignore-existing local/${bucket}; "
    done

    kubectl -n "$ns" delete job "${release}-init-buckets" --ignore-not-found >/dev/null 2>&1

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${release}-init-buckets
  labels: {app: ${release}}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: ${_SAAS_MC_IMAGE}
          env:
            - name: MINIO_USER
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootUser}}
            - name: MINIO_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: rootPassword}}
          command: ["/bin/sh", "-c"]
          args:
            - >
              mc alias set local http://${release}.${ns}.svc.cluster.local:9000 "\$MINIO_USER" "\$MINIO_PASSWORD" &&
              ${mb_cmds}
              echo done
EOF

    kubectl -n "$ns" wait --for=condition=complete --timeout=120s "job/${release}-init-buckets" 2>/dev/null \
        || kubectl -n "$ns" wait --for=condition=failed --timeout=1s "job/${release}-init-buckets" 2>/dev/null
    kubectl -n "$ns" get job "${release}-init-buckets" -o jsonpath='{.status.succeeded}' | grep -q 1
}

# _saas_minio_backend_delete NAMESPACE RELEASE
# Removes the workload (StatefulSet/Deployment/Service/Job), same as both gitlab/lib/datastore.sh
# delete functions: the PVC/Secret are deliberately left alone here (namespace-level --purge-storage
# in install.sh's 'delete' handles that, same precedent as gitlab/vault).
_saas_minio_backend_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete statefulset,deployment,service,job -l "app=${release}" --ignore-not-found >/dev/null 2>&1
}
