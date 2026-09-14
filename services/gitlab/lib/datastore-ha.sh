# --- HA PostgreSQL/Redis/MinIO for 'saas gitlab --mode prod' (--mode dev keeps datastore.sh, unchanged).
#
# "prod" now means real high availability, unconditionally, not an opt-in flag (see install.sh).
# PostgreSQL: CloudNativePG operator (3 instances, automatic failover). Redis: OT-CONTAINER-KIT
# redis-operator (RedisReplication + standalone RedisSentinel, 3 nodes each). MinIO: our own 4-node
# distributed StatefulSet (see datastore.sh, no operator needed, MinIO clusters itself). All three
# credentials are pre-seeded (same pattern as the dev-mode single-instance stack) so a down/up cycle
# keeps using the same passwords already baked into the data preserved on the host.
#
# Known trade-off, deliberate: the RedisSentinel CR is created WITHOUT its own 'kubernetesConfig.redisSecret'
# (leaving the Sentinel port, 26379, unauthenticated) while the actual Redis data connection stays fully
# password-protected via 'redisSentinelConfig.redisReplicationPassword' and the RedisReplication's own
# 'redisSecret'. This routes around a currently-open upstream bug (redis-operator #1871: auth on Sentinel's
# embedded-sentinel path). Sentinel only exposes topology/monitoring info, never data, so this is judged an
# acceptable trade-off. Revisit once that issue is fixed upstream.

_SAAS_GITLAB_CNPG_POSTGRESQL_IMAGE="ghcr.io/cloudnative-pg/postgresql:17"
_SAAS_GITLAB_REDIS_OPERATOR_REDIS_IMAGE="quay.io/opstree/redis:v7.2.16"
_SAAS_GITLAB_REDIS_OPERATOR_SENTINEL_IMAGE="quay.io/opstree/redis-sentinel:v7.2.16"

# _saas_gitlab_wait_for_resource NAMESPACE KIND NAME TIMEOUT_SECONDS
# Polls (every 5s) until 'kubectl get KIND/NAME' succeeds, i.e. the object actually EXISTS. Not the
# same thing 'kubectl rollout status'/'kubectl wait' check, both of which error out immediately (not
# "wait") if the object isn't there yet. Needed for resources some operators create with a delay
# after their owning CR is applied (observed live: redis-operator's Sentinel StatefulSet, created
# only after the RedisReplication side settles, sometimes over a minute later).
_saas_gitlab_wait_for_resource() {
    local ns="$1" kind="$2" name="$3" timeout="$4"
    local waited=0
    until kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; do
        [ "$waited" -ge "$timeout" ] && return 1
        sleep 5
        waited=$((waited + 5))
    done
}

# _saas_gitlab_datastore_ha_apply NAMESPACE RELEASE STORAGE_CLASS PSQL_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD REDIS_PASSWORD
_saas_gitlab_datastore_ha_apply() {
    local ns="$1" release="$2" storage_class="$3"
    local psql_password="$4" minio_user="$5" minio_password="$6" redis_password="$7"

    _saas_gitlab_operator_cnpg_ensure || return 1
    _saas_gitlab_operator_redis_ensure || return 1

    _saas_gitlab_datastore_secrets_apply "$ns" "$release" "$psql_password" "$minio_user" "$minio_password" || return 1

    kubectl -n "$ns" create secret generic "${release}-datastore-redis" \
        --type=kubernetes.io/basic-auth \
        --from-literal=username=default --from-literal=password="$redis_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    # Two separate variables for the same reason as datastore.sh's sc_field_pvc/sc_field_sts: the
    # CNPG Cluster's 'storage:' block and RedisReplication's 'volumeClaimTemplate.spec' need
    # storageClassName at two different indentation depths. A single shared variable here was
    # wrong at BOTH sites (verified live), never caught because --cluster-mode kind (this repo's
    # far more exercised path) always leaves storage_class empty; only --cluster-mode existing
    # (--mode prod) ever renders a non-empty value here.
    local sc_field_cnpg="" sc_field_redis=""
    [ -n "$storage_class" ] && sc_field_cnpg="    storageClassName: ${storage_class}"
    [ -n "$storage_class" ] && sc_field_redis="        storageClassName: ${storage_class}"

    _saas_log_step "Provisioning CloudNativePG (3-instance PostgreSQL HA)…"
    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${release}-postgresql
spec:
  instances: 3
  imageName: ${_SAAS_GITLAB_CNPG_POSTGRESQL_IMAGE}
  postgresql:
    parameters:
      max_locks_per_transaction: "256"
      max_connections: "200"
  bootstrap:
    initdb:
      database: gitlabhq_production
      owner: gitlab
      secret:
        name: ${release}-datastore-psql
      postInitSQL:
        - "CREATE DATABASE gitlabhq_production_ci;"
  storage:
${sc_field_cnpg}
    size: 20Gi
EOF

    _saas_log_wait "Waiting for the CloudNativePG cluster to become Ready…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=300s "cluster/${release}-postgresql" || return 1

    _saas_log_step "Provisioning Redis Sentinel HA (redis-operator)…"
    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisReplication
metadata:
  name: ${release}-redis
spec:
  clusterSize: 3
  kubernetesConfig:
    image: ${_SAAS_GITLAB_REDIS_OPERATOR_REDIS_IMAGE}
    redisSecret:
      name: ${release}-datastore-redis
      key: password
  storage:
    volumeClaimTemplate:
      spec:
        accessModes: ["ReadWriteOnce"]
${sc_field_redis}
        resources:
          requests:
            storage: 5Gi
---
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisSentinel
metadata:
  name: ${release}-redis
spec:
  clusterSize: 3
  redisSentinelConfig:
    redisReplicationName: ${release}-redis
    masterGroupName: mymaster
    redisReplicationPassword:
      secretKeyRef:
        name: ${release}-datastore-redis
        key: password
  kubernetesConfig:
    image: ${_SAAS_GITLAB_REDIS_OPERATOR_SENTINEL_IMAGE}
EOF

    # NOT 'kubectl wait --for=condition=Ready' here: verified live against the installed CRDs
    # (ot-helm/redis-operator 0.26.1): neither RedisReplication nor RedisSentinel's status schema
    # exposes a 'conditions' field at all in this version, so that wait can NEVER succeed regardless
    # of actual health. Wait on the underlying StatefulSets the operator creates instead (same name
    # as the CR for RedisReplication; '<CR-name>-sentinel' for RedisSentinel, confirmed from source).
    #
    # The Sentinel StatefulSet specifically is NOT created immediately when its CR is applied.
    # Observed live, over a minute's delay after the RedisReplication StatefulSet itself is already
    # rolled out (the operator appears to wait for the replication side to settle first), so
    # 'kubectl rollout status' on it right away fails hard with NotFound instead of waiting, unlike
    # a Deployment/StatefulSet that already exists. Poll for its existence first.
    _saas_log_wait "Waiting for the Redis Sentinel HA setup to become Ready…"
    kubectl -n "$ns" rollout status statefulset "${release}-redis" --timeout=300s || return 1
    _saas_gitlab_wait_for_resource "$ns" statefulset "${release}-redis-sentinel" 180 || {
        _saas_log_err "The '${release}-redis-sentinel' StatefulSet was never created by redis-operator."
        return 1
    }
    kubectl -n "$ns" rollout status statefulset "${release}-redis-sentinel" --timeout=300s || return 1

    _saas_gitlab_datastore_minio_ha_apply "$ns" "$release" "$storage_class" "$minio_user" "$minio_password" || return 1

    _saas_log_ok "HA PostgreSQL/Redis/MinIO ready."
}

# _saas_gitlab_datastore_ha_delete NAMESPACE RELEASE
_saas_gitlab_datastore_ha_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete cluster.postgresql.cnpg.io "${release}-postgresql" --ignore-not-found >/dev/null 2>&1
    kubectl -n "$ns" delete redisreplication "${release}-redis" --ignore-not-found >/dev/null 2>&1
    kubectl -n "$ns" delete redissentinel "${release}-redis" --ignore-not-found >/dev/null 2>&1
    kubectl -n "$ns" delete statefulset,service,job \
        -l "app=${release}-minio" --ignore-not-found >/dev/null 2>&1
}
