# --- The actual PostgreSQL workload for 'saas postgres': --mode dev (a single-instance
# StatefulSet, plain manifests, no chart) and --mode prod (a CloudNativePG-managed Cluster, real
# automatic failover via the operator promoted to lib/common.sh's _saas_ensure_cnpg_operator, same
# one 'saas gitlab --mode prod' already uses for its own HA PostgreSQL).
#
# TLS is enforced in both modes, not left plaintext (a standing decision for this service, unlike
# gitlab's own dev-mode private PostgreSQL, which stays in-cluster-only and plaintext since it's
# never meant to be reached the way a shared 'saas postgres' instance is). Verified live against the
# real postgres:17-alpine image before writing this:
#   - The image runs its 'postgres' server process as uid:gid 70:70 (NOT 999, confirmed with
#     'docker exec ... ps aux' and 'getent passwd postgres'; a common but wrong assumption for
#     Debian-based Postgres images doesn't hold for this Alpine-based one).
#   - PostgreSQL refuses to start with a TLS private key that's group/world-readable, and a
#     cert-manager Secret's mounted file can't have its mode narrowed directly at the volume level,
#     so an initContainer copies the Secret's files into a writable emptyDir and chmods the key.
#   - The image's default, auto-generated pg_hba.conf ends with a permissive
#     'host all all all scram-sha-256' line, which (per PostgreSQL's own connection-type semantics)
#     already accepts EITHER a plain or an SSL connection: 'host' matches both, only 'hostssl'/
#     'hostnossl' restrict to one or the other.
#   - REAL, LIVE FINDING while running a full 'saas gitlab install --database external' against
#     this service end to end: GitLab's own migrations (db:schema:load, loading its full
#     structure.sql in one transaction) fail outright with 'ERROR: out of shared memory / HINT:
#     You might need to increase "max_locks_per_transaction"' against this service's own DEFAULT
#     max_locks_per_transaction (64). This is the exact same constraint GitLab's own private
#     PostgreSQL already works around (see services/gitlab/lib/datastore.sh's identical args),
#     confirming it isn't GitLab-chart-specific but a genuine property of loading a schema this
#     large in a single transaction. Both modes here now default to the SAME
#     max_locks_per_transaction=256/max_connections=200 GitLab's own private instance already
#     uses, unconditionally (not just when a GitLab integration is detected): a generic standalone
#     PostgreSQL service meant for other SaaS services to consume benefits from this headroom
#     regardless of which consumer it ends up serving, and 64 is a needlessly tight default for
#     any nontrivial schema.
#   - REAL, LIVE BUG FOUND while testing this service's own admin tooling (database.sh), not caught
#     by the first round of manual TLS testing: the SAME default pg_hba.conf ALSO ships two
#     narrower, EARLIER 'host all all 127.0.0.1/32 trust' / 'host all all ::1/128 trust' rules (the
#     official image's own "convenient for local development" default), which grant trust (NO
#     PASSWORD CHECK AT ALL) to any TCP connection, encrypted or not, whose source address is
#     literally 127.0.0.1/::1. Since pg_hba.conf is first-match-wins by line ORDER (not
#     specificity), a single prepended 'hostnossl all all all reject' rule blocks plaintext
#     connections correctly (confirmed: 'sslmode=disable' from ANY address is rejected) but does
#     NOT stop an SSL connection FROM 127.0.0.1 from matching one of those trust lines next,
#     bypassing password authentication entirely. This matters here specifically because THIS
#     service's own admin tooling (database.sh's _saas_postgres_psql_run) always connects via
#     'host=127.0.0.1' (see that file for why), so an incomplete fix would have made this service's
#     own credential checks silently meaningless. Reproduced live: with only the 'hostnossl' rule in
#     place, a DELIBERATELY WRONG password still authenticated successfully over
#     'host=127.0.0.1 sslmode=require'. Fixed by prepending a SECOND rule, 'hostssl all all all
#     scram-sha-256', immediately after the 'hostnossl' one and BEFORE any of the image's own
#     built-in rules: together the two prepended lines claim every possible TCP connection (SSL or
#     not, any address) before the built-in trust/permissive rules are ever reached, making those
#     later lines permanently unreachable, which is exactly the intent. Re-verified live end to end
#     after the fix: a wrong password now fails authentication even over 'host=127.0.0.1
#     sslmode=require', and the correct password still succeeds; 'sslmode=disable' still rejected
#     outright regardless of address, exactly as before.
#   - These two rules are added by a 'docker-entrypoint-initdb.d/00-hostssl.sh' script, which the
#     official image's entrypoint runs (sourced, not executed, since a ConfigMap-mounted file isn't
#     executable) exactly once, only against a freshly-initialized, empty data directory, before
#     the server's first real start. On every later restart against the SAME PersistentVolumeClaim,
#     initdb.d scripts do NOT re-run, but the rules are already persisted in pg_hba.conf on disk, so
#     enforcement survives 'saas postgres down'/'up' by construction, with no extra code needed.
#
# CloudNativePG (--mode prod) findings, also verified live against a real installed operator
# (chart cnpg/cloudnative-pg 0.29.0) before writing this:
#   - Pointing 'certificates.serverTLSSecret'/'serverCASecret' at the SAME cert-manager-issued
#     Secret works with no key-name friction: CNPG accepts the combined tls.crt/tls.key/ca.crt
#     Secret cert-manager already produces for both fields, no separate derived Secret needed.
#   - Setting 'certificates.*' alone does NOT enforce TLS-only client connections: CNPG's own
#     managed pg_hba.conf, confirmed live by reading it straight out of a running instance, ends
#     with the exact same permissive 'host all all all scram-sha-256' line the plain image defaults
#     to (see above), which accepts plaintext just as readily as SSL. An explicit
#     'spec.postgresql.pg_hba: ["hostnossl all all all reject"]' entry is required, same technique
#     as dev mode. Confirmed live that CNPG inserts operator-supplied pg_hba entries BEFORE that
#     final default line (first-match-wins still applies), so this one entry is sufficient; verified
#     end to end exactly like dev mode, sslmode=disable rejected, sslmode=require accepted.
#   - The admin role name cannot be 'postgres': CNPG's 'bootstrap.initdb.owner' creates a new,
#     non-superuser application role, and 'postgres' is reserved for CNPG's own real superuser
#     (whose password stays unset/unmanaged unless 'enableSuperuserAccess'/'superuserSecret' are
#     used too, a separate, more privileged mechanism this service deliberately doesn't use).
#     Reproduced live: 'owner: postgres' is silently accepted by the CRD but the role's password is
#     never actually set from the given secret, so authentication as 'postgres' fails outright no
#     matter what password is supplied. This is WHY this service's own default admin username
#     (install.sh) is 'admin', not 'postgres': a name that works identically and correctly as an
#     ordinary role in both dev mode (the plain image's POSTGRES_USER, which happily creates a
#     custom-named superuser under any name) and prod mode (CNPG's owner field), with no special
#     case needed between the two.
#   - CNPG's bootstrap owner role also starts with NO CREATEDB/CREATEROLE, confirmed live
#     (rolcreatedb/rolcreaterole both false; a real 'CREATE DATABASE'/'CREATE ROLE' attempt as that
#     role fails with "permission denied"), unlike dev mode's admin user, which is a real superuser
#     and so already has both implicitly. '_saas_postgres_prod_apply' grants them once, right after
#     the Cluster becomes Ready, via a LOCAL peer-authenticated connection as the real 'postgres'
#     superuser (no password ever read or stored for it, see below) so database.sh's role/database
#     management works identically in both modes afterward.
#   - The main container is named 'postgres' in BOTH modes on purpose (not 'postgresql' in dev
#     mode), matching CNPG's own container name: every 'kubectl exec ... -c postgres' call in this
#     service (database.sh, credentials.sh, doctor.sh) then works unchanged regardless of mode.
#   - Administrative psql calls (database.sh) always connect over TCP to 127.0.0.1 with
#     sslmode=require, authenticating with the admin role's own password, in BOTH modes, rather than
#     a bare local-socket connection. Verified live why a local-socket connection can't be the
#     uniform choice: the plain image's default local rule is 'local all all trust' (works for any
#     role, no password), but CNPG's own managed local rule is 'local all all peer map=local'
#     (matches ONLY when the connecting OS user's name equals the target role name), so a local-
#     socket connection AS the admin role fails outright under CNPG unless the admin role happens to
#     be named 'postgres' (the one OS user actually present in the container), which is exactly the
#     reserved name this service avoids (see above). TCP+sslmode=require sidesteps this entirely and
#     is already exactly what an external client uses, so it's one uniform code path instead of a
#     mode-dependent branch.
#   - REAL, LIVE BUG FOUND testing '--expose': a plain ClusterIP Service isn't reachable at all
#     from the separate docker container 'saas cluster expose add' runs to publish a host port (the
#     same socat-proxy mechanism services/gitlab/lib/ssh.sh already uses for GitLab's own SSH
#     exposure). Reproduced live: 'saas cluster expose add' itself warns the resolved ClusterIP
#     "doesn't look like it belongs to the 'kind' docker network's subnet", and a client connecting
#     through the published host port gets "server closed the connection unexpectedly" or a
#     pg_hba.conf rejection from an unexpected source address, never a real connection. Root cause:
#     a Kubernetes Service's ClusterIP is only reachable via each node's own iptables DNAT rules,
#     invisible to a sibling docker container outside the cluster's node network namespaces
#     entirely, structurally different from a real routable address. 'saas cluster create' already
#     installs MetalLB by default (confirmed live: its IP pool, e.g. 172.18.4.0/24, sits inside the
#     'kind' docker network's own subnet), so a 'type: LoadBalancer' Service gets a real address
#     that sibling containers on that same docker network CAN reach directly, no DNAT involved.
#     '_saas_postgres_dev_apply' makes the Service 'type: LoadBalancer' precisely when EXPOSE is
#     true (never unconditionally, to not consume a MetalLB pool address for every install
#     regardless of whether --expose was ever requested); verified live end to end afterward, both
#     the plaintext-rejection and the real SSL connection succeed through the published host port.
#     --mode prod (CNPG) is a KNOWN, DELIBERATELY UNRESOLVED gap for --expose: CNPG manages its own
#     '-rw'/'-r'/'-ro' Services and, while it does support overriding them via
#     'spec.managed.services', wiring that up wasn't done in this pass (same class of documented,
#     deliberately-untested gap as MinIO's/Vault's own cross-cluster limitations, see CLAUDE.md);
#     install.sh refuses '--expose' together with '--mode prod' outright, with that explanation,
#     rather than silently accepting a combination that wouldn't actually work.

_saas_postgres_valid_mode()     { [[ "$1" == "dev" || "$1" == "prod" ]]; }
_saas_postgres_valid_workers()  { [[ "$1" =~ ^[0-9]+$ ]]; }
_saas_postgres_valid_hostport() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
# PostgreSQL identifier rules: lowercase start letter/underscore, then letters/digits/underscores.
_saas_postgres_valid_username()      { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }
_saas_postgres_valid_database_name() { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

# The postgres image's own uid:gid, verified live (see file header); needed to chown the TLS key
# before the main container (which runs as this same uid) can read it.
_SAAS_POSTGRES_UID_GID="70:70"
# Small, already-pinned image (same version this repo already uses elsewhere for a throwaway
# root-capable fixup step, services/cluster/lib/delete.sh's --purge-storage fallback), reused here
# rather than introducing a new base image just for a chown+chmod.
_SAAS_POSTGRES_INITCONTAINER_IMAGE="busybox:1.38.0"

# _saas_postgres_secrets_apply NAMESPACE RELEASE USERNAME PASSWORD
# The one admin credentials Secret, shared by dev and prod mode: kubernetes.io/basic-auth (so it can
# also be used verbatim as a CloudNativePG 'bootstrap.initdb.secret' in --mode prod, which requires
# that exact type/shape), keys 'username'/'password'.
_saas_postgres_secrets_apply() {
    local ns="$1" release="$2" username="$3" password="$4"
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
    kubectl -n "$ns" create secret generic "${release}-credentials" \
        --type=kubernetes.io/basic-auth \
        --from-literal=username="$username" --from-literal=password="$password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# _saas_postgres_dev_apply NAMESPACE RELEASE STORAGE_CLASS USERNAME TLS_SECRET EXPOSE
# --mode dev: single instance, no operator. USERNAME/its password come from the
# '<release>-credentials' Secret (already applied by the caller via _saas_postgres_secrets_apply).
# EXPOSE (true/false) decides the Service's type, see the file header's LoadBalancer/MetalLB note.
_saas_postgres_dev_apply() {
    local ns="$1" release="$2" storage_class="$3" username="$4" tls_secret="$5" expose="${6:-false}"

    local sc_field=""
    [ -n "$storage_class" ] && sc_field="        storageClassName: ${storage_class}"
    local svc_type_field=""
    [ "$expose" = "true" ] && svc_type_field="  type: LoadBalancer"

    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${release}-postgresql-initdb
data:
  00-hostssl.sh: |
    TMP="\$(mktemp)"
    { echo "hostnossl all all all reject"; echo "hostssl all all all scram-sha-256"; cat "\$PGDATA/pg_hba.conf"; } > "\$TMP" && mv "\$TMP" "\$PGDATA/pg_hba.conf"
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
      initContainers:
        - name: fix-tls-perms
          image: ${_SAAS_POSTGRES_INITCONTAINER_IMAGE}
          command: ["sh", "-c", "cp /tls-src/tls.crt /tls-src/tls.key /tls/ && { [ -f /tls-src/ca.crt ] && cp /tls-src/ca.crt /tls/ || true; } && chown ${_SAAS_POSTGRES_UID_GID} /tls/tls.crt /tls/tls.key && { [ -f /tls/ca.crt ] && chown ${_SAAS_POSTGRES_UID_GID} /tls/ca.crt || true; } && chmod 600 /tls/tls.key"]
          volumeMounts:
            - {name: tls-src, mountPath: /tls-src, readOnly: true}
            - {name: tls, mountPath: /tls}
      containers:
        - name: postgres
          image: postgres:17-alpine
          # Pinned to the same uid:gid the entrypoint's own internal privilege drop already uses
          # when started as root (see the file header): declaring it explicitly, rather than
          # leaving it implicit, makes 'kubectl exec' sessions (database.sh, doctor.sh) run as this
          # same non-root user too, not root. Verified live this matters in practice: 'kubectl exec'
          # otherwise defaults to root (the image sets no Dockerfile USER of its own), and
          # doctor.sh's 'pg_ctl reload' fix script fails outright with "pg_ctl: cannot be run as
          # root" without this.
          securityContext: {runAsUser: 70, runAsGroup: 70}
          args: ["-c", "ssl=on", "-c", "ssl_cert_file=/tls/tls.crt", "-c", "ssl_key_file=/tls/tls.key",
                 "-c", "max_locks_per_transaction=256", "-c", "max_connections=200"]
          ports: [{containerPort: 5432}]
          env:
            - name: POSTGRES_USER
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: username}}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: ${release}-credentials, key: password}}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          resources:
            requests: {cpu: 100m, memory: 256Mi}
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}
            - {name: initdb, mountPath: /docker-entrypoint-initdb.d}
            - {name: tls, mountPath: /tls}
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "${username}"]}
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: initdb
          configMap: {name: ${release}-postgresql-initdb}
        - name: tls-src
          secret: {secretName: ${tls_secret}}
        - name: tls
          emptyDir: {}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
${sc_field}
        resources: {requests: {storage: 2Gi}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${release}-postgresql
spec:
${svc_type_field}
  selector: {app: ${release}-postgresql}
  ports: [{port: 5432, targetPort: 5432}]
EOF

    _saas_log_wait "Waiting for PostgreSQL to be ready…"
    kubectl -n "$ns" rollout status statefulset "${release}-postgresql" --timeout=180s
}

# _saas_postgres_dev_delete NAMESPACE RELEASE
_saas_postgres_dev_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete statefulset,service,configmap \
        -l "app=${release}-postgresql" --ignore-not-found >/dev/null 2>&1
}

# _saas_postgres_prod_apply NAMESPACE RELEASE STORAGE_CLASS USERNAME TLS_SECRET
# --mode prod: CloudNativePG-managed 3-instance Cluster, real automatic failover. TLS uses CNPG's
# own native 'certificates' field instead of dev mode's manual initContainer/pg_hba dance: CNPG
# already terminates TLS itself and manages its pg_hba.conf, so pointing it at the same
# cert-manager-issued Secret this service already has is enough.
_saas_postgres_prod_apply() {
    local ns="$1" release="$2" storage_class="$3" username="$4" tls_secret="$5"

    _saas_ensure_cnpg_operator || return 1

    local sc_field=""
    [ -n "$storage_class" ] && sc_field="    storageClassName: ${storage_class}"

    _saas_log_step "Provisioning CloudNativePG (3-instance PostgreSQL HA)…"
    kubectl apply -n "$ns" -f - <<EOF || return 1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${release}-postgresql
spec:
  instances: 3
  imageName: ${_SAAS_CNPG_POSTGRESQL_IMAGE}
  bootstrap:
    initdb:
      database: postgres
      owner: ${username}
      secret:
        name: ${release}-credentials
  storage:
${sc_field}
    size: 20Gi
  certificates:
    serverTLSSecret: ${tls_secret}
    serverCASecret: ${tls_secret}
  postgresql:
    parameters:
      max_locks_per_transaction: "256"
      max_connections: "200"
    pg_hba:
      - "hostnossl all all all reject"
EOF

    _saas_log_wait "Waiting for the CloudNativePG cluster to become Ready…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=300s "cluster/${release}-postgresql" || return 1

    # CNPG's bootstrap owner role is deliberately unprivileged beyond owning the bootstrap database
    # itself (verified live: rolcreatedb/rolcreaterole are both false), unlike dev mode's admin user,
    # which the plain image always makes a real superuser regardless of its name. Grant CREATEDB/
    # CREATEROLE once, idempotent, so database.sh's role/database management works the same way in
    # both modes. Run via the primary pod's local unix socket as the real 'postgres' superuser,
    # authenticated by peer auth (matching OS user, no password ever needed or read): CNPG's own
    # pg_hba.conf maps this locally regardless of 'enableSuperuserAccess' (a separate, more
    # privileged mechanism, deliberately not used here), so this never needs the superuser's own
    # password, which this service never sets, reads, or stores anywhere.
    local primary
    primary="$(_saas_postgres_primary_pod "$ns" "$release" prod)"
    [ -n "$primary" ] || { _saas_log_err "Could not resolve the CloudNativePG cluster's primary pod."; return 1; }
    kubectl -n "$ns" exec "$primary" -c postgres -- psql -U postgres -d postgres \
        -c "ALTER ROLE ${username} CREATEDB CREATEROLE" >/dev/null
}

# _saas_postgres_prod_delete NAMESPACE RELEASE
_saas_postgres_prod_delete() {
    local ns="$1" release="$2"
    kubectl -n "$ns" delete cluster.postgresql.cnpg.io "${release}-postgresql" --ignore-not-found >/dev/null 2>&1
}

# _saas_postgres_primary_pod NAMESPACE RELEASE MODE
# Resolves the pod to run 'psql'/administrative commands against: dev mode always has exactly one
# pod (the StatefulSet's own '-0'); prod mode's CNPG Cluster exposes its current primary via
# 'status.currentPrimary' (verified live: CNPG's Cluster CRD, unlike redis-operator's CRDs, genuinely
# has a real status subresource with this field, same "verify against the real installed CRD"
# discipline this repo already applies elsewhere).
_saas_postgres_primary_pod() {
    local ns="$1" release="$2" mode="$3"
    if [ "$mode" = "prod" ]; then
        kubectl -n "$ns" get cluster "${release}-postgresql" -o jsonpath='{.status.currentPrimary}' 2>/dev/null
    else
        echo "${release}-postgresql-0"
    fi
}
