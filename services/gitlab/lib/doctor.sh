# --- Diagnostics (and, with --fix, repair) for 'saas gitlab', covering the failure modes observed in practice after a real host reboot mid-session: pods stuck in 'Unknown' phase, the PostgreSQL password no longer matching what's baked into the persisted data directory, the 4 MinIO-derived Secrets drifting from MinIO's own actual running credentials, and the kind-expose-* SSH proxy container not coming back on its own (kind/Docker don't guarantee it survives a host restart).
#
# Diagnose-only by default; nothing is touched unless --fix is passed, so a bare 'doctor' call is always safe to run. Each check is split into a pure '_check_*' function (diagnosis only, unit-testable with a mocked kubectl/docker, no real cluster needed) and a '_fix_*' function (only invoked when --fix is passed and the check actually found a problem).
#
# The PostgreSQL check/fix (B) only applies to --mode dev's single-instance StatefulSet (datastore.sh); --mode prod's CloudNativePG-managed Cluster (datastore-ha.sh) reconciles its own credentials/pg_hba.conf and must not be hand-edited the same way, so it's skipped there.

_saas_gitlab_doctor_help() {
    cat <<'EOF'
Usage: saas gitlab doctor [RELEASE] [OPTIONS]

Diagnoses common problems left behind by things outside this tool's
control, most notably a host reboot mid-session: pods stuck in
'Unknown' phase, the PostgreSQL password no longer matching the
persisted data directory (--mode dev only), the 4 MinIO-derived
Secrets drifting from MinIO's own actual credentials, and a dead
kind-expose-* SSH proxy container.

By default only reports what it finds; nothing is changed unless
--fix is passed.

Options:
      --fix    Apply repairs for every problem found
  -h, --help   Show this help

Examples:
  saas gitlab doctor
  saas gitlab doctor demo --fix
EOF
}

# --------------------------------------------------------------------
# A. Pod health
# --------------------------------------------------------------------

# _saas_gitlab_doctor_check_pods NAMESPACE
# One pod name per line, for every pod currently in phase "Unknown".
_saas_gitlab_doctor_check_pods() {
    local ns="$1"
    kubectl -n "$ns" get pods -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase == "Unknown") | .metadata.name'
}

# _saas_gitlab_doctor_fix_pods NAMESPACE POD1 [POD2...]
_saas_gitlab_doctor_fix_pods() {
    local ns="$1"; shift
    local pod
    for pod in "$@"; do
        kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1
    done
}

# --------------------------------------------------------------------
# B. PostgreSQL password drift (--mode dev only)
# --------------------------------------------------------------------

# _saas_gitlab_doctor_check_psql NAMESPACE RELEASE PASSWORD
# Prints "ok", "mismatch", or "unreachable".
_saas_gitlab_doctor_check_psql() {
    local ns="$1" release="$2" password="$3"
    local pod="${release}-postgresql-0"

    kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 || { echo "unreachable"; return; }

    if kubectl -n "$ns" exec "$pod" -- env PGPASSWORD="$password" \
        psql -U gitlab -d gitlabhq_production -tAc 'SELECT 1' >/dev/null 2>&1; then
        echo "ok"
    else
        echo "mismatch"
    fi
}

# _saas_gitlab_doctor_fix_psql NAMESPACE RELEASE PASSWORD
# Resets the 'gitlab' role's password to PASSWORD via a temporary 'trust' rule prepended to
# pg_hba.conf, reloaded with 'pg_ctl reload' (no DB auth needed for that, unlike a psql-issued
# 'SELECT pg_reload_conf()', which would need to already authenticate under the OLD, possibly
# broken rules). The original pg_hba.conf is always restored on exit, success or failure (the trap),
# so a partial failure never leaves 'trust' auth active.
_saas_gitlab_doctor_fix_psql() {
    local ns="$1" release="$2" password="$3"
    local pod="${release}-postgresql-0"

    local script
    script="$(cat <<'SCRIPT'
set -e
hba="$PGDATA/pg_hba.conf"
cp "$hba" "$hba.saas-doctor-bak"
trap 'mv "$hba.saas-doctor-bak" "$hba" 2>/dev/null; pg_ctl reload -D "$PGDATA" >/dev/null 2>&1' EXIT
{ echo "local all all trust"; cat "$hba"; } > "$hba.tmp" && mv "$hba.tmp" "$hba"
pg_ctl reload -D "$PGDATA"
psql -U gitlab -d gitlabhq_production -c "ALTER USER gitlab WITH PASSWORD '__SAAS_DOCTOR_PASSWORD__'"
SCRIPT
)"
    script="${script//__SAAS_DOCTOR_PASSWORD__/$password}"

    kubectl -n "$ns" exec -i "$pod" -- sh -c "$script"
}

# --------------------------------------------------------------------
# C. MinIO secret drift (the 4 Secrets datastore.sh derives from the MinIO root credentials)
# --------------------------------------------------------------------

# _saas_gitlab_doctor_check_minio NAMESPACE RELEASE
# First line: the MinIO pod's actual MINIO_ROOT_PASSWORD (the source of truth, since that's what
# GitLab is really authenticating against). Following lines, if any: the names of the Secrets whose
# derived password no longer matches it. No output at all (and a nonzero exit) if the MinIO pod
# itself isn't reachable.
_saas_gitlab_doctor_check_minio() {
    local ns="$1" release="$2"
    local minio_pod
    minio_pod="$(kubectl -n "$ns" get pods -l "app=${release}-minio" -o name 2>/dev/null | head -n1 | sed 's#^pod/##')"
    [ -n "$minio_pod" ] || return 1

    local real_password
    real_password="$(kubectl -n "$ns" exec "$minio_pod" -- printenv MINIO_ROOT_PASSWORD 2>/dev/null)"
    [ -n "$real_password" ] || return 1
    echo "$real_password"

    local secret_password
    secret_password="$(kubectl -n "$ns" get secret "${release}-datastore-minio" -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d)"
    [ "$secret_password" = "$real_password" ] || echo "${release}-datastore-minio"

    secret_password="$(kubectl -n "$ns" get secret "${release}-datastore-registry-storage" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d | sed -n 's/^ *secretkey: *//p')"
    [ "$secret_password" = "$real_password" ] || echo "${release}-datastore-registry-storage"

    secret_password="$(kubectl -n "$ns" get secret "${release}-datastore-s3cfg" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d | sed -n 's/^secret_key = //p')"
    [ "$secret_password" = "$real_password" ] || echo "${release}-datastore-s3cfg"

    secret_password="$(kubectl -n "$ns" get secret "${release}-datastore-objectstore" -o jsonpath='{.data.connection}' 2>/dev/null | base64 -d | sed -n 's/^aws_secret_access_key: //p')"
    [ "$secret_password" = "$real_password" ] || echo "${release}-datastore-objectstore"
}

# _saas_gitlab_doctor_fix_minio NAMESPACE RELEASE REAL_PASSWORD
# Re-applies all 4 Secrets with REAL_PASSWORD (reusing _saas_gitlab_datastore_secrets_apply,
# already idempotent), then restarts the registry/toolbox Deployments, since Kubernetes doesn't
# restart a pod just because a Secret it mounts changed, and updates the saved state so future
# 'credentials'/'install' calls stay in sync.
_saas_gitlab_doctor_fix_minio() {
    local ns="$1" release="$2" real_password="$3"

    local minio_user
    minio_user="$(kubectl -n "$ns" get secret "${release}-datastore-minio" -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d)"
    [ -n "$minio_user" ] || minio_user="${SAAS_GITLAB_STATE_MINIO_ROOT_USER:-}"
    [ -n "$minio_user" ] || { _saas_log_err "Could not determine the MinIO root user."; return 1; }

    _saas_gitlab_datastore_minio_secrets_apply "$ns" "$release" "$minio_user" "$real_password" || return 1

    local deploy
    deploy="$(kubectl -n "$ns" get deployment -o name 2>/dev/null | grep -m1 "${release}-registry" | sed 's#^deployment.apps/##')"
    [ -n "$deploy" ] && kubectl -n "$ns" rollout restart deployment "$deploy" >/dev/null 2>&1
    deploy="$(kubectl -n "$ns" get deployment -o name 2>/dev/null | grep -m1 "${release}-toolbox" | sed 's#^deployment.apps/##')"
    [ -n "$deploy" ] && kubectl -n "$ns" rollout restart deployment "$deploy" >/dev/null 2>&1

    _saas_gitlab_state_save_key "$release" "MINIO_ROOT_PASSWORD" "$real_password"
}

# --------------------------------------------------------------------
# D. kind-expose-* SSH proxy (--cluster-mode kind only)
# --------------------------------------------------------------------

# _saas_gitlab_doctor_check_expose KIND_NAME HOST_PORT
# True if a running container is currently publishing HOST_PORT for KIND_NAME (same
# 'kind-cluster.expose.*' labels _kind_cluster_expose_add itself uses to detect a duplicate).
_saas_gitlab_doctor_check_expose() {
    local kind_name="$1" host_port="$2"
    docker ps --filter "label=kind-cluster.expose.cluster=${kind_name}" \
              --filter "label=kind-cluster.expose.hostport=${host_port}" \
              --filter "label=kind-cluster.expose.protocol=tcp" \
              --format '{{.Names}}' 2>/dev/null | grep -q .
}

# _saas_gitlab_doctor_fix_expose KIND_NAME NAMESPACE RELEASE HOST_PORT
# Reuses _saas_gitlab_ssh_expose (ssh.sh) as-is: it already does a blind remove+add.
_saas_gitlab_doctor_fix_expose() {
    local kind_name="$1" ns="$2" release="$3" host_port="$4"
    _saas_gitlab_ssh_expose "$kind_name" "$ns" "$release" "$host_port"
}

# --------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------

_saas_gitlab_doctor() {
    local fix=false
    local args
    args=$(getopt -o h -l fix,help --name saas_gitlab_doctor -- "$@") || { _saas_gitlab_doctor_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --fix) fix=true; shift ;;
            -h|--help) _saas_gitlab_doctor_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
    local ns="$SAAS_GITLAB_STATE_NAMESPACE"
    local problems=0

    echo ""
    echo "Doctor: '$release'$($fix && echo ' (--fix: repairs will be applied)')"
    echo ""

    # A. Pod health
    local -a unknown_pods=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && unknown_pods+=("$line"); done < <(_saas_gitlab_doctor_check_pods "$ns")
    if [ "${#unknown_pods[@]}" -eq 0 ]; then
        echo "✅ Pods: none stuck in 'Unknown' phase."
    else
        problems=$((problems + 1))
        echo "⚠️  Pods: ${#unknown_pods[@]} stuck in 'Unknown' phase: ${unknown_pods[*]}"
        if $fix; then
            _saas_gitlab_doctor_fix_pods "$ns" "${unknown_pods[@]}"
            echo "   🔧 Force-deleted; their controller will recreate them."
        fi
    fi

    # B. PostgreSQL password (--mode dev only)
    if [ "$SAAS_GITLAB_STATE_MODE" = "prod" ]; then
        echo "ℹ️  PostgreSQL: --mode prod (CloudNativePG-managed), not covered by this check."
    else
        local psql_status
        psql_status="$(_saas_gitlab_doctor_check_psql "$ns" "$release" "${SAAS_GITLAB_STATE_PSQL_PASSWORD:-}")"
        case "$psql_status" in
            ok)
                echo "✅ PostgreSQL: the saved password authenticates fine."
                ;;
            unreachable)
                echo "⚠️  PostgreSQL: pod '${release}-postgresql-0' not reachable, skipped."
                ;;
            mismatch)
                problems=$((problems + 1))
                echo "⚠️  PostgreSQL: the saved password does NOT authenticate against the live database."
                if $fix; then
                    if _saas_gitlab_doctor_fix_psql "$ns" "$release" "${SAAS_GITLAB_STATE_PSQL_PASSWORD:-}"; then
                        echo "   🔧 Password reset via a temporary 'trust' rule; it now matches the saved state."
                    else
                        echo "   ❌ Could not reset the PostgreSQL password, see the error above."
                    fi
                fi
                ;;
        esac
    fi

    # C. MinIO secrets
    if [ "${SAAS_GITLAB_STATE_OBJECT_STORAGE_MODE:-internal}" = "external" ]; then
        echo "ℹ️  MinIO: --object-storage external (managed by 'saas minio'), not covered by this check."
    else
    local -a minio_out=()
    while IFS= read -r line; do [ -n "$line" ] && minio_out+=("$line"); done < <(_saas_gitlab_doctor_check_minio "$ns" "$release")
    if [ "${#minio_out[@]}" -eq 0 ]; then
        echo "⚠️  MinIO: pod not reachable, skipped."
    else
        local real_password="${minio_out[0]}"
        local -a stale_secrets=("${minio_out[@]:1}")
        if [ "${#stale_secrets[@]}" -eq 0 ]; then
            echo "✅ MinIO: all 4 derived Secrets match the running pod's credentials."
        else
            problems=$((problems + 1))
            echo "⚠️  MinIO: ${#stale_secrets[@]} Secret(s) out of sync with the running pod: ${stale_secrets[*]}"
            if $fix; then
                if _saas_gitlab_doctor_fix_minio "$ns" "$release" "$real_password"; then
                    echo "   🔧 Reconciled all 4 Secrets and restarted registry/toolbox to pick them up."
                else
                    echo "   ❌ Could not reconcile the MinIO Secrets, see the error above."
                fi
            fi
        fi
    fi
    fi

    # D. kind-expose SSH proxy
    if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ] && [ -n "${SAAS_GITLAB_STATE_SSH_HOST_PORT:-}" ]; then
        if _saas_gitlab_doctor_check_expose "$SAAS_GITLAB_STATE_KIND_NAME" "$SAAS_GITLAB_STATE_SSH_HOST_PORT"; then
            echo "✅ SSH proxy: kind-expose-* container running on port $SAAS_GITLAB_STATE_SSH_HOST_PORT."
        else
            problems=$((problems + 1))
            echo "⚠️  SSH proxy: no running kind-expose-* container on port $SAAS_GITLAB_STATE_SSH_HOST_PORT."
            if $fix; then
                if _saas_gitlab_doctor_fix_expose "$SAAS_GITLAB_STATE_KIND_NAME" "$ns" "$release" "$SAAS_GITLAB_STATE_SSH_HOST_PORT"; then
                    echo "   🔧 Proxy recreated."
                else
                    echo "   ❌ Could not recreate the SSH proxy, see the error above."
                fi
            fi
        fi
    fi

    echo ""
    if [ "$problems" -eq 0 ]; then
        _saas_log_ok "Nothing to report."
    elif $fix; then
        _saas_log_ok "Ran repairs for $problems problem(s). Re-run 'saas gitlab doctor $release' to confirm."
    else
        _saas_log_warn "$problems problem(s) found. Re-run with --fix to repair them."
    fi
}
