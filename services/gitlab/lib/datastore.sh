# --- Minimal PostgreSQL/Redis/MinIO for 'saas gitlab' (--mode dev; --mode prod uses datastore-ha.sh instead).
#
# Design finding: the official gitlab/gitlab chart no longer bundles PostgreSQL/Redis/MinIO (as of a certain version it requires EXTERNAL PostgreSQL/Redis/object storage, confirmed live with 'helm show values gitlab/gitlab'). Since this project is "self-hosted, no external dependencies", --mode dev deploys its own single-instance PostgreSQL/Redis/MinIO (plain manifests, no third-party chart) to cover that gap. Deliberately no HA: a disposable local stack where a password-protected Redis or multi-replica anything buys nothing real. --mode prod instead gets genuine HA via third-party operators, see datastore-ha.sh.
#
# The credentials (PostgreSQL password, MinIO root credentials) are generated once and persisted in 'saas gitlab''s own state (services/gitlab/lib/state.sh) so that the down/up cycle (which recreates these Secrets from scratch) keeps using the SAME password already baked into the data files preserved on the host. If they didn't match, PostgreSQL would start up with data that no longer accepts that password.

_SAAS_GITLAB_MINIO_BUCKETS=(
    registry git-lfs gitlab-artifacts gitlab-uploads gitlab-packages
    gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files
    gitlab-agent-plan-content gitlab-ci-catalog-bundles
    gitlab-dependency-proxy gitlab-backups gitlab-pages
)

# _saas_gitlab_datastore_psql_secret_apply NAMESPACE RELEASE PSQL_PASSWORD
# Shared by both --mode dev (this file) and --mode prod (datastore-ha.sh), same name/keys in both
# modes. Always called regardless of --object-storage: PostgreSQL/Redis stay internal to 'saas
# gitlab' either way, only object storage is ever externalized (see install.sh).
_saas_gitlab_datastore_psql_secret_apply() {
    local ns="$1" release="$2" psql_password="$3"

    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    # kubernetes.io/basic-auth (username+password) so the same Secret can also be pre-seeded as a
    # CloudNativePG 'bootstrap.initdb.secret' in --mode prod (CNPG requires that exact type/shape).
    kubectl -n "$ns" create secret generic "${release}-datastore-psql" \
        --type=kubernetes.io/basic-auth \
        --from-literal=username=gitlab --from-literal=password="$psql_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
}

# _saas_gitlab_datastore_minio_secrets_apply NAMESPACE RELEASE MINIO_ROOT_USER MINIO_ROOT_PASSWORD
# The 4 MinIO-derived Secrets, shared by both --mode dev (this file) and --mode prod
# (datastore-ha.sh), same names/keys in both modes, so the values templates never need to know
# which datastore backs them. Only called with --object-storage internal (default): with
# 'external', these same 4 Secret names are instead applied by 'saas gitlab integrate minio' (see
# services/gitlab/lib/minio_integration.sh and services/minio/values/gitlab-datastore-secrets.yaml.tpl),
# pointing at a shared MinIO instance instead of this release's own private one.
_saas_gitlab_datastore_minio_secrets_apply() {
    local ns="$1" release="$2" minio_user="$3" minio_password="$4"

    kubectl -n "$ns" create secret generic "${release}-datastore-minio" \
        --from-literal=rootUser="$minio_user" --from-literal=rootPassword="$minio_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    local objectstore_connection
    objectstore_connection="$(cat <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: ${minio_user}
aws_secret_access_key: ${minio_password}
host: ${release}-minio.${ns}.svc.cluster.local:9000
endpoint: http://${release}-minio.${ns}.svc.cluster.local:9000
path_style: true
EOF
)"
    kubectl -n "$ns" create secret generic "${release}-datastore-objectstore" \
        --from-literal=connection="$objectstore_connection" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    # The chart's toolbox (also used by us to mint the 'root' PAT for runner registration) unconditionally copies an .s3cfg file (s3cmd format) on startup whenever backups.objectStorage.backend is 's3' (the default). Verified in practice: without this secret, the toolbox pod goes into CrashLoopBackOff even if no backup functionality is ever used. We give it one pointing at the same MinIO.
    local s3cfg
    s3cfg="$(cat <<EOF
[default]
access_key = ${minio_user}
secret_key = ${minio_password}
host_base = ${release}-minio.${ns}.svc.cluster.local:9000
host_bucket = ${release}-minio.${ns}.svc.cluster.local:9000
use_https = False
check_ssl_certificate = False
EOF
)"
    kubectl -n "$ns" create secret generic "${release}-datastore-s3cfg" \
        --from-literal=config="$s3cfg" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    # Container Registry storage config: the registry subchart does NOT reuse global.appConfig.object_store
    # (verified against the chart's own values.yaml). It needs its own 'registry.storage.secret', a
    # Secret whose 'config' key is the registry's native S3 driver config, spliced into its config.yml at
    # startup. Created unconditionally (cheap, harmless if --registry is off), same precedent as .s3cfg above.
    #
    # checksum_disabled: true is required against MinIO: GitLab's registry always uses its AWS
    # SDK v2 based S3 driver internally (DriverName s3_v2 in its own logs) even though this config
    # still uses the 's3' key, not 's3_v2'. That SDK sends a CRC64NVME checksum by default on
    # multipart UploadPartCopy requests, which MinIO rejects with "InvalidArgument: checksum
    # missing", failing every push. This is GitLab's own documented fix for S3-compatible backends
    # (Ceph, MinIO, etc.). Known limitation from that same guidance: a push that triggers a blob
    # deletion (DeleteObjects) can still fail, since GitLab has no equivalent config knob for it.
    #
    # pathstyle: true is GitLab's own documented recommendation for MinIO/Ceph RGW/most
    # S3-compatible backends, kept regardless of whether it fixes any specific observed failure.
    #
    # redirect.disable: true: without it, the registry answers blob (image layer) requests with a
    # 302 straight to MinIO's own in-cluster Service address, a ClusterIP unreachable from outside
    # the cluster (manifest/auth resolve fine over the public ingress; only the blob download
    # fails). Disabling redirect makes the registry proxy blob bytes through itself instead,
    # GitLab's documented setting for registries with no public storage backend. The "worse
    # performance, less attack surface" tradeoff GitLab's own docs mention is a non-issue for a
    # local dev registry at this scale.
    local registry_storage
    registry_storage="$(cat <<EOF
s3:
  bucket: registry
  v4auth: true
  regionendpoint: http://${release}-minio.${ns}.svc.cluster.local:9000
  region: minio
  accesskey: ${minio_user}
  secretkey: ${minio_password}
  secure: false
  pathstyle: true
  checksum_disabled: true
redirect:
  disable: true
EOF
)"
    kubectl -n "$ns" create secret generic "${release}-datastore-registry-storage" \
        --from-literal=config="$registry_storage" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
}

# _saas_gitlab_datastore_apply NAMESPACE RELEASE STORAGE_CLASS OBJECT_STORAGE_MODE PSQL_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD
# --mode dev only (see datastore-ha.sh for --mode prod). OBJECT_STORAGE_MODE: 'internal' (default,
# unchanged behavior) deploys this release's own private MinIO, same as before this parameter
# existed; 'external' skips it entirely, relying on Secrets 'saas gitlab integrate minio' already
# applied (see install.sh, which refuses to proceed with 'external' if they're missing).
_saas_gitlab_datastore_apply() {
    local ns="$1" release="$2" storage_class="$3" object_storage_mode="$4"
    local psql_password="$5" minio_user="$6" minio_password="$7"

    local psql_storage="2Gi"
    local psql_cpu="200m" psql_mem="512Mi" redis_cpu="50m" redis_mem="128Mi"

    # Two separate variables, not one reused at both indentation depths: this function (and
    # _saas_gitlab_datastore_minio_internal_apply below) emit storageClassName at two structurally
    # different nesting levels (a StatefulSet's volumeClaimTemplates[].spec vs. a standalone
    # PersistentVolumeClaim's spec), and YAML's indentation is meaningful. A single shared variable
    # here was a real, live bug (see CLAUDE.md): correct at the standalone-PVC site, but wrong at
    # the StatefulSet site, silently never caught because --cluster-mode kind always leaves
    # storage_class empty (only --cluster-mode existing ever renders a non-empty value here).
    local sc_field_sts=""
    [ -n "$storage_class" ] && sc_field_sts="        storageClassName: ${storage_class}"

    _saas_gitlab_datastore_psql_secret_apply "$ns" "$release" "$psql_password" || return 1
    if [ "$object_storage_mode" = "internal" ]; then
        _saas_gitlab_datastore_minio_secrets_apply "$ns" "$release" "$minio_user" "$minio_password" || return 1
    fi

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${release}-postgresql-initdb
data:
  01-extra-databases.sql: |
    CREATE DATABASE gitlabhq_production_ci;
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${release}-postgresql
  labels: {app: ${release}-postgresql}
spec:
  serviceName: ${release}-postgresql
  replicas: 1
  selector:
    matchLabels: {app: ${release}-postgresql}
  template:
    metadata:
      labels: {app: ${release}-postgresql}
    spec:
      containers:
        - name: postgresql
          image: postgres:17-alpine
          args:
            - -c
            - max_locks_per_transaction=256
            - -c
            - max_connections=200
          ports: [{containerPort: 5432}]
          env:
            - {name: POSTGRES_USER, value: gitlab}
            - {name: POSTGRES_DB, value: gitlabhq_production}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-datastore-psql, key: password}}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          resources:
            requests: {cpu: ${psql_cpu}, memory: ${psql_mem}}
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}
            - {name: initdb, mountPath: /docker-entrypoint-initdb.d}
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "gitlab"]}
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: initdb
          configMap: {name: ${release}-postgresql-initdb}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
${sc_field_sts}
        resources: {requests: {storage: ${psql_storage}}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}-postgresql
spec:
  selector: {app: ${release}-postgresql}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${release}-redis
  labels: {app: ${release}-redis}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${release}-redis}
  template:
    metadata:
      labels: {app: ${release}-redis}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports: [{containerPort: 6379}]
          resources:
            requests: {cpu: ${redis_cpu}, memory: ${redis_mem}}
          readinessProbe:
            exec: {command: ["redis-cli", "ping"]}
            initialDelaySeconds: 3
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}-redis
spec:
  selector: {app: ${release}-redis}
  ports: [{port: 6379, targetPort: 6379}]
EOF

    _saas_log_wait "Waiting for PostgreSQL/Redis to be ready…"
    kubectl -n "$ns" rollout status statefulset "${release}-postgresql" --timeout=180s || return 1
    kubectl -n "$ns" rollout status deployment "${release}-redis" --timeout=120s || return 1

    if [ "$object_storage_mode" = "internal" ]; then
        _saas_gitlab_datastore_minio_internal_apply "$ns" "$release" "$storage_class" || return 1
    else
        _saas_log_info "Object storage: external (managed by 'saas minio'), no private MinIO deployed here."
    fi

    _saas_log_ok "PostgreSQL/Redis ready."
}

# _saas_gitlab_datastore_minio_internal_apply NAMESPACE RELEASE STORAGE_CLASS
# This release's own single-instance MinIO Deployment/PVC/Service, extracted out of
# _saas_gitlab_datastore_apply so it can be skipped entirely with --object-storage external. Only
# called with 'internal' (the default); the 4 MinIO-derived Secrets it depends on
# (_saas_gitlab_datastore_minio_secrets_apply) must already have been applied by the caller.
_saas_gitlab_datastore_minio_internal_apply() {
    local ns="$1" release="$2" storage_class="$3"
    local minio_storage="5Gi" minio_cpu="100m" minio_mem="256Mi"
    local sc_field_pvc=""
    [ -n "$storage_class" ] && sc_field_pvc="  storageClassName: ${storage_class}"

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${release}-minio
  labels: {app: ${release}-minio}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${release}-minio}
  template:
    metadata:
      labels: {app: ${release}-minio}
    spec:
      containers:
        - name: minio
          image: ${_SAAS_MINIO_IMAGE}
          args: ["server", "/data", "--console-address", ":9001"]
          ports: [{containerPort: 9000}, {containerPort: 9001}]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootUser}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootPassword}}
          resources:
            requests: {cpu: ${minio_cpu}, memory: ${minio_mem}}
          volumeMounts:
            - {name: data, mountPath: /data}
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: ${release}-minio-data}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${release}-minio-data
spec:
  accessModes: [ReadWriteOnce]
${sc_field_pvc}
  resources: {requests: {storage: ${minio_storage}}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}-minio
spec:
  selector: {app: ${release}-minio}
  ports: [{name: api, port: 9000, targetPort: 9000}, {name: console, port: 9001, targetPort: 9001}]
EOF

    _saas_log_wait "Waiting for MinIO to be ready…"
    kubectl -n "$ns" rollout status deployment "${release}-minio" --timeout=120s || return 1

    _saas_gitlab_datastore_init_buckets "$ns" "$release" || return 1
    _saas_log_ok "MinIO ready."
}

# _saas_gitlab_datastore_minio_ha_apply NAMESPACE RELEASE STORAGE_CLASS MINIO_ROOT_USER MINIO_ROOT_PASSWORD
# --mode prod: 4-node MinIO distributed mode, MinIO's own clustering via its startup command, no
# operator needed. The normal ClusterIP Service '${release}-minio' is kept identical to --mode dev
# (same name, selects all 4 pods) so every client (objectstore/.s3cfg/registry-storage secrets, the
# bucket-init Job below) is completely unaware of whether MinIO is 1 or 4 nodes.
_saas_gitlab_datastore_minio_ha_apply() {
    local ns="$1" release="$2" storage_class="$3" minio_user="$4" minio_password="$5"

    local minio_storage="50Gi" minio_cpu="500m" minio_mem="1Gi"
    local sc_field=""
    [ -n "$storage_class" ] && sc_field="        storageClassName: ${storage_class}"

    # Three dots in '{0...3}' is required by MinIO's own ellipsis syntax for server pools. Two dots
    # gets shell-expanded locally by the container's entrypoint and breaks erasure-set ordering.
    local minio_endpoint="http://${release}-minio-{0...3}.${release}-minio-headless.${ns}.svc.cluster.local/data"

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: v1
kind: Service
metadata:
  name: ${release}-minio-headless
  labels: {app: ${release}-minio}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: {app: ${release}-minio}
  ports: [{name: api, port: 9000, targetPort: 9000}]
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}-minio
  labels: {app: ${release}-minio}
spec:
  selector: {app: ${release}-minio}
  ports: [{name: api, port: 9000, targetPort: 9000}, {name: console, port: 9001, targetPort: 9001}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${release}-minio
  labels: {app: ${release}-minio}
spec:
  serviceName: ${release}-minio-headless
  replicas: 4
  selector:
    matchLabels: {app: ${release}-minio}
  template:
    metadata:
      labels: {app: ${release}-minio}
    spec:
      containers:
        - name: minio
          image: ${_SAAS_MINIO_IMAGE}
          args: ["server", "${minio_endpoint}", "--console-address", ":9001"]
          ports: [{containerPort: 9000}, {containerPort: 9001}]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootUser}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootPassword}}
          resources:
            requests: {cpu: ${minio_cpu}, memory: ${minio_mem}}
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
        resources: {requests: {storage: ${minio_storage}}}
EOF

    _saas_log_wait "Waiting for the 4-node MinIO cluster to be ready…"
    kubectl -n "$ns" rollout status statefulset "${release}-minio" --timeout=300s || return 1

    _saas_gitlab_datastore_init_buckets "$ns" "$release" || return 1
    _saas_log_ok "MinIO (4-node distributed) ready."
}

# _saas_gitlab_datastore_init_buckets NAMESPACE RELEASE
# Ephemeral job with 'mc' that (idempotently) creates the buckets global.appConfig.object_store expects from the chart.
_saas_gitlab_datastore_init_buckets() {
    local ns="$1" release="$2"
    local mb_cmds=""
    local bucket
    for bucket in "${_SAAS_GITLAB_MINIO_BUCKETS[@]}"; do
        mb_cmds+="mc mb --ignore-existing local/${bucket}; "
    done

    kubectl -n "$ns" delete job "${release}-minio-init-buckets" --ignore-not-found >/dev/null 2>&1

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${release}-minio-init-buckets
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
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootUser}}
            - name: MINIO_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-datastore-minio, key: rootPassword}}
          command: ["/bin/sh", "-c"]
          args:
            - >
              mc alias set local http://${release}-minio.${ns}.svc.cluster.local:9000 "\$MINIO_USER" "\$MINIO_PASSWORD" &&
              ${mb_cmds}
              echo done
EOF

    kubectl -n "$ns" wait --for=condition=complete --timeout=120s "job/${release}-minio-init-buckets" 2>/dev/null \
        || kubectl -n "$ns" wait --for=condition=failed --timeout=1s "job/${release}-minio-init-buckets" 2>/dev/null
    kubectl -n "$ns" get job "${release}-minio-init-buckets" -o jsonpath='{.status.succeeded}' | grep -q 1
}

# _saas_gitlab_datastore_delete NAMESPACE RELEASE
# --mode dev only (see datastore-ha.sh for --mode prod).
_saas_gitlab_datastore_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete statefulset,deployment,service,configmap,job \
        -l "app in (${release}-postgresql,${release}-redis,${release}-minio)" --ignore-not-found >/dev/null 2>&1
}
