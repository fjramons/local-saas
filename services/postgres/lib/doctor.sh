# --- Diagnostics (and, with --fix, repair) for 'saas postgres'. Section B (credential drift) is
# --mode dev only, reusing verbatim the same 'pg_ctl reload'/temporary-'trust'/'ALTER USER'
# technique services/gitlab/lib/doctor.sh already implements for its own private dev-mode
# PostgreSQL. --mode prod (CloudNativePG-managed) is explicitly skipped there, same reasoning as
# gitlab's own doctor: CNPG reconciles its own credentials/pg_hba.conf continuously, and hand-
# editing it the same way would fight the operator's own reconciliation loop.

_saas_postgres_doctor_help() {
    cat <<'EOF'
Usage: saas postgres doctor [RELEASE] [OPTIONS]

Diagnoses common problems left behind by things outside this tool's
control, most notably a host reboot mid-session: pods stuck in
'Unknown' phase, the admin password no longer matching the persisted
data directory (--mode dev only), and a dead kind-expose-* proxy
container (only if --expose was used).

By default only reports what it finds; nothing is changed unless
--fix is passed.

A rotated '<release>-credentials' Secret (e.g. after 'saas vault
integrate postgres' syncs a new password from Vault) is exactly the
kind of drift this command's --fix reconciles: unlike MinIO, a
Postgres role's real password is a database-level fact, not just
something a pod restart alone can fix, so 'doctor --fix' (not a mere
restart) is the actual mechanism that makes a Vault-rotated Secret
take effect against the running database.

Options:
      --fix    Apply repairs for every problem found
  -h, --help   Show this help

Examples:
  saas postgres doctor
  saas postgres doctor demo --fix
EOF
}

# --------------------------------------------------------------------
# A. Pod health
# --------------------------------------------------------------------

_saas_postgres_doctor_check_pods() {
    local ns="$1"
    kubectl -n "$ns" get pods -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase == "Unknown") | .metadata.name'
}

_saas_postgres_doctor_fix_pods() {
    local ns="$1"; shift
    local pod
    for pod in "$@"; do
        kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1
    done
}

# --------------------------------------------------------------------
# B. Admin credential drift (--mode dev only)
# --------------------------------------------------------------------

# _saas_postgres_doctor_check_credentials NAMESPACE POD USERNAME PASSWORD
# Prints "ok", "mismatch", or "unreachable".
_saas_postgres_doctor_check_credentials() {
    local ns="$1" pod="$2" username="$3" password="$4"
    kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 || { echo "unreachable"; return; }

    if _saas_postgres_psql_run "$ns" "$pod" "$username" "$password" postgres 'SELECT 1' >/dev/null 2>&1; then
        echo "ok"
    else
        echo "mismatch"
    fi
}

# _saas_postgres_doctor_fix_credentials NAMESPACE POD USERNAME PASSWORD
# --mode dev only. Same technique as services/gitlab/lib/doctor.sh's _saas_gitlab_doctor_fix_psql:
# a temporary 'trust' rule is prepended to pg_hba.conf, reloaded with 'pg_ctl reload' (no DB auth
# needed for that, unlike a psql-issued 'SELECT pg_reload_conf()', which would need to already
# authenticate under the OLD, possibly broken rules), then the password is reset. The original
# pg_hba.conf is always restored on exit, success or failure (the trap), so a partial failure never
# leaves 'trust' auth active.
_saas_postgres_doctor_fix_credentials() {
    local ns="$1" pod="$2" username="$3" password="$4"

    local script
    script="$(cat <<'SCRIPT'
set -e
hba="$PGDATA/pg_hba.conf"
cp "$hba" "$hba.saas-doctor-bak"
trap 'mv "$hba.saas-doctor-bak" "$hba" 2>/dev/null; pg_ctl reload -D "$PGDATA" >/dev/null 2>&1' EXIT
{ echo "local all all trust"; cat "$hba"; } > "$hba.tmp" && mv "$hba.tmp" "$hba"
pg_ctl reload -D "$PGDATA"
psql -U __SAAS_DOCTOR_USER__ -d postgres -c "ALTER USER __SAAS_DOCTOR_USER__ WITH PASSWORD '__SAAS_DOCTOR_PASSWORD__'"
SCRIPT
)"
    script="${script//__SAAS_DOCTOR_USER__/$username}"
    script="${script//__SAAS_DOCTOR_PASSWORD__/$password}"

    kubectl -n "$ns" exec -i "$pod" -c postgres -- sh -c "$script"
}

# --------------------------------------------------------------------
# C. kind-expose-* proxy (--cluster-mode kind + --expose only)
# --------------------------------------------------------------------

_saas_postgres_doctor_check_expose() {
    local kind_name="$1" host_port="$2"
    docker ps --filter "label=kind-cluster.expose.cluster=${kind_name}" \
              --filter "label=kind-cluster.expose.hostport=${host_port}" \
              --filter "label=kind-cluster.expose.protocol=tcp" \
              --format '{{.Names}}' 2>/dev/null | grep -q .
}

_saas_postgres_doctor_fix_expose() {
    local kind_name="$1" ns="$2" release="$3" host_port="$4"
    _saas_postgres_expose "$kind_name" "$ns" "$release" "$host_port"
}

# --------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------

_saas_postgres_doctor() {
    local fix=false
    local args
    args=$(getopt -o h -l fix,help --name saas_postgres_doctor -- "$@") || { _saas_postgres_doctor_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --fix) fix=true; shift ;;
            -h|--help) _saas_postgres_doctor_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
    local ns="$SAAS_POSTGRES_STATE_NAMESPACE"
    local problems=0

    echo ""
    echo "Doctor: '$release'$($fix && echo ' (--fix: repairs will be applied)')"
    echo ""

    # A. Pod health
    local -a unknown_pods=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && unknown_pods+=("$line"); done < <(_saas_postgres_doctor_check_pods "$ns")
    if [ "${#unknown_pods[@]}" -eq 0 ]; then
        echo "✅ Pods: none stuck in 'Unknown' phase."
    else
        problems=$((problems + 1))
        echo "⚠️  Pods: ${#unknown_pods[@]} stuck in 'Unknown' phase: ${unknown_pods[*]}"
        if $fix; then
            _saas_postgres_doctor_fix_pods "$ns" "${unknown_pods[@]}"
            echo "   🔧 Force-deleted; their controller will recreate them."
        fi
    fi

    # B. Admin credentials (--mode dev only)
    if [ "$SAAS_POSTGRES_STATE_MODE" = "prod" ]; then
        echo "ℹ️  Credentials: --mode prod (CloudNativePG-managed), not covered by this check."
    else
        local pod="${release}-postgresql-0"
        local cred_status
        cred_status="$(_saas_postgres_doctor_check_credentials "$ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "${SAAS_POSTGRES_STATE_ADMIN_PASSWORD:-}")"
        case "$cred_status" in
            ok)
                echo "✅ Credentials: the saved password authenticates fine."
                ;;
            unreachable)
                echo "⚠️  Credentials: pod '$pod' not reachable, skipped."
                ;;
            mismatch)
                problems=$((problems + 1))
                echo "⚠️  Credentials: the saved password does NOT authenticate against the live database."
                if $fix; then
                    if _saas_postgres_doctor_fix_credentials "$ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "${SAAS_POSTGRES_STATE_ADMIN_PASSWORD:-}"; then
                        echo "   🔧 Password reset via a temporary 'trust' rule; it now matches the saved state."
                    else
                        echo "   ❌ Could not reset the admin password, see the error above."
                    fi
                fi
                ;;
        esac
    fi

    # C. kind-expose proxy
    if [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ] && [ "${SAAS_POSTGRES_STATE_EXPOSE:-false}" = "true" ]; then
        if _saas_postgres_doctor_check_expose "$SAAS_POSTGRES_STATE_KIND_NAME" "$SAAS_POSTGRES_STATE_HOST_PORT"; then
            echo "✅ Host exposure: kind-expose-* container running on port $SAAS_POSTGRES_STATE_HOST_PORT."
        else
            problems=$((problems + 1))
            echo "⚠️  Host exposure: no running kind-expose-* container on port $SAAS_POSTGRES_STATE_HOST_PORT."
            if $fix; then
                if _saas_postgres_doctor_fix_expose "$SAAS_POSTGRES_STATE_KIND_NAME" "$ns" "$release" "$SAAS_POSTGRES_STATE_HOST_PORT"; then
                    echo "   🔧 Proxy recreated."
                else
                    echo "   ❌ Could not recreate the proxy, see the error above."
                fi
            fi
        fi
    fi

    echo ""
    if [ "$problems" -eq 0 ]; then
        _saas_log_ok "Nothing to report."
    elif $fix; then
        _saas_log_ok "Ran repairs for $problems problem(s). Re-run 'saas postgres doctor $release' to confirm."
    else
        _saas_log_warn "$problems problem(s) found. Re-run with --fix to repair them."
    fi
}
