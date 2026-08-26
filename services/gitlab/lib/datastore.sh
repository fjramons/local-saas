# --- Minimal PostgreSQL/Redis/MinIO for 'saas gitlab'.
#
# Design finding (see CLAUDE.md): the official gitlab/gitlab chart no longer bundles PostgreSQL/Redis/MinIO (as of a certain version it requires EXTERNAL PostgreSQL/Redis/object storage — confirmed live with 'helm show values gitlab/gitlab'). Since this project is "self-hosted, no external dependencies", we deploy our own single-instance PostgreSQL/Redis/MinIO (plain manifests, no third-party chart) to cover that gap. This is not high availability — documented as a known limitation, see CLAUDE.md.
#
# The credentials (PostgreSQL password, MinIO root credentials) are generated once and persisted in 'saas gitlab''s own state (services/gitlab/lib/state.sh) so that the down/up cycle (which recreates these Secrets from scratch) keeps using the SAME password already baked into the data files preserved on the host — if they didn't match, PostgreSQL would start up with data that no longer accepts that password.

_SAAS_GITLAB_MINIO_BUCKETS=(
    registry git-lfs gitlab-artifacts gitlab-uploads gitlab-packages
    gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files
    gitlab-agent-plan-content gitlab-ci-catalog-bundles
    gitlab-dependency-proxy gitlab-backups gitlab-pages
)

# _saas_gitlab_datastore_apply NAMESPACE RELEASE MODE STORAGE_CLASS PSQL_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD
_saas_gitlab_datastore_apply() {
    local ns="$1" release="$2" mode="$3" storage_class="$4"
    local psql_password="$5" minio_user="$6" minio_password="$7"

    local psql_storage="2Gi" minio_storage="5Gi"
    local psql_cpu="200m" psql_mem="512Mi" minio_cpu="100m" minio_mem="256Mi" redis_cpu="50m" redis_mem="128Mi"
    if [ "$mode" = "prod" ]; then
        psql_storage="20Gi"; minio_storage="50Gi"
        psql_cpu="1"; psql_mem="2Gi"; minio_cpu="500m"; minio_mem="1Gi"; redis_cpu="200m"; redis_mem="512Mi"
    fi

    local sc_field=""
    [ -n "$storage_class" ] && sc_field="  storageClassName: ${storage_class}"

    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    kubectl -n "$ns" create secret generic "${release}-datastore-psql" \
        --from-literal=password="$psql_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

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

    # The chart's toolbox (also used by us to mint the 'root' PAT for runner registration) unconditionally copies an .s3cfg file (s3cmd format) on startup whenever backups.objectStorage.backend is 's3' (the default) — verified in practice: without this secret, the toolbox pod goes into CrashLoopBackOff even if no backup functionality is ever used. We give it one pointing at the same MinIO.
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
${sc_field}
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
---
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
          image: minio/minio:RELEASE.2025-09-07T16-13-09Z
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
${sc_field}
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

    _saas_log_wait "Waiting for PostgreSQL/Redis/MinIO to be ready…"
    kubectl -n "$ns" rollout status statefulset "${release}-postgresql" --timeout=180s || return 1
    kubectl -n "$ns" rollout status deployment "${release}-redis" --timeout=120s || return 1
    kubectl -n "$ns" rollout status deployment "${release}-minio" --timeout=120s || return 1

    _saas_gitlab_datastore_init_buckets "$ns" "$release" || return 1
    _saas_log_ok "PostgreSQL/Redis/MinIO ready."
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
          image: minio/mc:RELEASE.2025-08-13T08-35-41Z
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
_saas_gitlab_datastore_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete statefulset,deployment,service,configmap,job \
        -l "app in (${release}-postgresql,${release}-redis,${release}-minio)" --ignore-not-found >/dev/null 2>&1
}
