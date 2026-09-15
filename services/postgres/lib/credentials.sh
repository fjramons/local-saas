# --- Connection info/credentials for 'saas postgres'. Printed in plain by default, like 'saas
# gitlab credentials'/'saas minio credentials' (an app-level admin password, not a whole-secrets-
# store master key the way Vault's root token/unseal keys are, so there's no reveal-gating
# precedent to follow here).

_saas_postgres_credentials_help() {
    cat <<'EOF'
Usage: saas postgres credentials [RELEASE] [OPTIONS]

Prints the in-cluster connection string, the external host:port (if
--expose was used at install time), and the admin username/password.

Options:
      --verify   Also perform a live check that the admin credentials
                actually authenticate against the running instance
  -h, --help     Show this help
EOF
}

_saas_postgres_credentials() {
    local release="" verify=false
    local args
    args=$(getopt -o h -l verify,help --name saas_postgres_credentials -- "$@") || { _saas_postgres_credentials_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --verify)  verify=true; shift ;;
            -h|--help) _saas_postgres_credentials_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    local host="${SAAS_POSTGRES_STATE_RELEASE}-postgresql.${SAAS_POSTGRES_STATE_NAMESPACE}.svc.cluster.local"
    echo "In-cluster connection: postgresql://${SAAS_POSTGRES_STATE_USERNAME}:${SAAS_POSTGRES_STATE_ADMIN_PASSWORD}@${host}:5432/postgres?sslmode=require"
    if [ "${SAAS_POSTGRES_STATE_EXPOSE:-false}" = "true" ]; then
        echo "Host connection:        psql \"host=127.0.0.1 port=${SAAS_POSTGRES_STATE_HOST_PORT} sslmode=require\""
    fi
    echo "Admin user:             $SAAS_POSTGRES_STATE_USERNAME"
    echo "Admin password:         $SAAS_POSTGRES_STATE_ADMIN_PASSWORD"

    if $verify; then
        local pod
        pod="$(_saas_postgres_primary_pod "$SAAS_POSTGRES_STATE_NAMESPACE" "$release" "$SAAS_POSTGRES_STATE_MODE")"
        if [ -n "$pod" ] && _saas_postgres_psql_run "$SAAS_POSTGRES_STATE_NAMESPACE" "$pod" \
            "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" postgres 'SELECT 1' >/dev/null 2>&1; then
            _saas_log_ok "--verify: the admin credentials authenticate fine."
        else
            _saas_log_err "--verify: the admin credentials do NOT authenticate. Try 'saas postgres doctor $release --fix'."
            return 1
        fi
    fi
}
