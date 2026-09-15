# --- 'saas postgres database create|list|drop': logical database (and, optionally, dedicated role)
# management. Runs 'psql' directly via 'kubectl exec' against the release's own primary pod
# (resolved by backend.sh's _saas_postgres_primary_pod, container 'postgres' in both modes): unlike
# MinIO's 'bucket' subcommand, no throwaway pod with a separate client image is needed here, since
# PostgreSQL's own server image already bundles 'psql'.
#
# Connects over TCP to 127.0.0.1 with sslmode=require, password-authenticated as the admin role, in
# BOTH modes, deliberately NOT a bare local-socket connection. Verified live (see backend.sh) why a
# local-socket connection can't be the uniform choice: dev mode's default local rule is
# 'local all all trust' (any role, no password), but CNPG's (--mode prod) own managed local rule is
# 'local all all peer map=local' (only matches when the connecting OS user's name equals the target
# role name), which fails outright for any admin role name other than the one reserved OS user
# actually present in the container ('postgres', deliberately never used as this service's own admin
# role name, see backend.sh). TCP+sslmode=require is exactly what an external client already uses,
# so this is one uniform code path instead of a mode-dependent branch, and it exercises the same
# 'hostssl'-only enforcement backend.sh sets up, rather than bypassing it.
#
# Credential model: one shared admin credential ('<release>-credentials') is the default; every
# database created with no --owner is simply owned by that same admin user, no new Secret. An
# explicit --owner NAME creates (idempotently, reusing an already-persisted password on a re-run,
# never regenerating one over an already-running consumer's credentials) a dedicated role plus a
# companion '<release>-<owner>-credentials' Secret (same kubernetes.io/basic-auth shape). This
# matches GitLab's own expectation exactly: it wants exactly one username/password pair (role
# 'gitlab') owning both 'gitlabhq_production' and 'gitlabhq_production_ci' (see gitlab_integration.sh).

# _saas_postgres_psql_run NAMESPACE POD USERNAME PASSWORD DBNAME SQL
# Runs one SQL statement via 'psql -tAc', over TCP to 127.0.0.1 with sslmode=require (see the file
# header for why, never a bare local-socket connection). Prints psql's own stdout; a failing
# statement returns nonzero.
_saas_postgres_psql_run() {
    local ns="$1" pod="$2" username="$3" password="$4" dbname="$5" sql="$6"
    kubectl -n "$ns" exec "$pod" -c postgres -- env PGPASSWORD="$password" \
        psql "host=127.0.0.1 user=${username} dbname=${dbname} sslmode=require" -tAc "$sql"
}

# _saas_postgres_role_password NAMESPACE RELEASE OWNER
# Prints the already-persisted password for a companion '<release>-<owner>-credentials' Secret, if
# one exists; empty otherwise (first time this owner is used).
_saas_postgres_role_password() {
    local ns="$1" release="$2" owner="$3"
    kubectl -n "$ns" get secret "${release}-${owner}-credentials" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null
}

# _saas_postgres_database_create_internal NAMESPACE POD ADMIN_USERNAME ADMIN_PASSWORD RELEASE DBNAME [OWNER]
# The actual mutation (idempotent): creates OWNER's role if it doesn't exist yet (reusing its
# already-persisted password on a re-run), creates DBNAME if it doesn't exist yet, and grants OWNER
# full ownership. With no OWNER, DBNAME is simply owned by the release's own admin user, no new role
# or Secret. Kept separate from the public 'database create' subcommand so it's directly callable
# (and stubbable in unit tests) from gitlab_integration.sh, mirroring how MinIO's own
# _saas_minio_init_buckets is the one call-counter target in its own integration tests.
_saas_postgres_database_create_internal() {
    local ns="$1" pod="$2" admin_user="$3" admin_password="$4" release="$5" dbname="$6" owner="${7:-}"

    local owner_user="$admin_user" owner_password="$admin_password"
    if [ -n "$owner" ] && [ "$owner" != "$admin_user" ]; then
        owner_password="$(_saas_postgres_role_password "$ns" "$release" "$owner")"
        if [ -z "$owner_password" ]; then
            owner_password="$(_saas_random_password 32)"
            _saas_log_step "Creating role '${owner}'…"
            _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
                "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${owner}') THEN CREATE ROLE ${owner} LOGIN PASSWORD '${owner_password}'; END IF; END \$\$;" || return 1
            kubectl -n "$ns" create secret generic "${release}-${owner}-credentials" \
                --type=kubernetes.io/basic-auth \
                --from-literal=username="$owner" --from-literal=password="$owner_password" \
                --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
        fi
        # Membership in OWNER is required for admin_user to CREATE/ALTER a database OWNER-ed by it,
        # regardless of whether the role already existed (PostgreSQL requires the executing role to
        # be able to SET ROLE to the target owner). Verified live: without this grant, both
        # 'CREATE DATABASE ... OWNER owner' and 'ALTER DATABASE ... OWNER TO owner' fail outright
        # with "must be able to SET ROLE", even though admin_user already has CREATEDB/CREATEROLE.
        _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
            "GRANT ${owner} TO ${admin_user}" >/dev/null || return 1
        owner_user="$owner"
    fi

    if ! _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
        "SELECT 1 FROM pg_database WHERE datname = '${dbname}'" | grep -q 1; then
        _saas_log_step "Creating database '${dbname}' (owner: ${owner_user})…"
        _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
            "CREATE DATABASE ${dbname} OWNER ${owner_user}" || return 1
    else
        _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
            "ALTER DATABASE ${dbname} OWNER TO ${owner_user}" >/dev/null || return 1
    fi
    _saas_postgres_psql_run "$ns" "$pod" "$admin_user" "$admin_password" postgres \
        "GRANT ALL PRIVILEGES ON DATABASE ${dbname} TO ${owner_user}" >/dev/null
}

_saas_postgres_database_help() {
    cat <<'EOF'
Usage: saas postgres database SUBCOMMAND [OPTIONS]

Subcommands:
  create NAME    Create a database (idempotent)
  list           List all databases
  drop NAME      Drop a database

Options (all subcommands):
      --release NAME   The postgres release (default: suggested if only
                        one exists)
  -h, --help            Show this help

Options (create only):
      --owner NAME   Role that owns the new database (default: the
                      release's own admin user). If NAME differs from the
                      admin user and doesn't exist yet, a new role is
                      created with a freshly generated password, and a
                      companion '<release>-<owner>-credentials' Secret
                      (same kubernetes.io/basic-auth shape as
                      '<release>-credentials') is created with it.
                      Re-running 'create' with the same --owner reuses
                      that role's already-persisted password (idempotent,
                      never regenerates over an already-running
                      consumer's credentials)

Options (drop only):
  -y, --yes   Don't ask for confirmation

Examples:
  saas postgres database create mydb
  saas postgres database create gitlabhq_production --owner gitlab
  saas postgres database list
  saas postgres database drop mydb
EOF
}

_saas_postgres_database() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift
    case "$subcommand" in
        create) _saas_postgres_database_create "$@" ;;
        list)   _saas_postgres_database_list "$@" ;;
        drop)   _saas_postgres_database_drop "$@" ;;
        ""|-h|--help|help)
            _saas_postgres_database_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'database ${subcommand}'"
            _saas_postgres_database_help >&2
            return 1
            ;;
    esac
}

_saas_postgres_database_create() {
    local release="" owner="" dbname=""
    local args
    args=$(getopt -o h -l release:,owner:,help --name saas_postgres_database_create -- "$@") || {
        _saas_postgres_database_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            --owner)   owner="$2"; shift 2 ;;
            -h|--help) _saas_postgres_database_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    dbname="${1:-}"
    [ -n "$dbname" ] || { _saas_log_err "A database NAME is required."; return 1; }
    _saas_postgres_valid_database_name "$dbname" || {
        _saas_log_err "'$dbname' isn't a valid PostgreSQL identifier (lowercase letters/digits/underscores, starting with a letter or underscore)."
        return 1
    }
    if [ -n "$owner" ]; then
        _saas_postgres_valid_username "$owner" || { _saas_log_err "--owner '$owner' isn't a valid PostgreSQL role name."; return 1; }
    fi
    [ -n "$release" ] || release="$(_saas_postgres_suggest_release)"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    local ns="$SAAS_POSTGRES_STATE_NAMESPACE"
    local pod
    pod="$(_saas_postgres_primary_pod "$ns" "$release" "$SAAS_POSTGRES_STATE_MODE")"
    [ -n "$pod" ] || { _saas_log_err "Could not resolve the primary pod for release '$release'."; return 1; }

    _saas_postgres_database_create_internal "$ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" \
        "$release" "$dbname" "$owner" || return 1
    _saas_log_ok "Database '$dbname' ready (owner: ${owner:-$SAAS_POSTGRES_STATE_USERNAME})."
}

_saas_postgres_database_list() {
    local release=""
    local args
    args=$(getopt -o h -l release:,help --name saas_postgres_database_list -- "$@") || { _saas_postgres_database_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            -h|--help) _saas_postgres_database_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    [ -n "$release" ] || release="$(_saas_postgres_suggest_release)"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    local ns="$SAAS_POSTGRES_STATE_NAMESPACE"
    local pod
    pod="$(_saas_postgres_primary_pod "$ns" "$release" "$SAAS_POSTGRES_STATE_MODE")"
    [ -n "$pod" ] || { _saas_log_err "Could not resolve the primary pod for release '$release'."; return 1; }

    _saas_postgres_psql_run "$ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" postgres \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
}

_saas_postgres_database_drop() {
    local release="" yes=false dbname=""
    local args
    args=$(getopt -o yh -l release:,yes,help --name saas_postgres_database_drop -- "$@") || { _saas_postgres_database_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            -y|--yes)  yes=true; shift ;;
            -h|--help) _saas_postgres_database_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    dbname="${1:-}"
    [ -n "$dbname" ] || { _saas_log_err "A database NAME is required."; return 1; }
    [ -n "$release" ] || release="$(_saas_postgres_suggest_release)"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    local ns="$SAAS_POSTGRES_STATE_NAMESPACE"
    local pod
    pod="$(_saas_postgres_primary_pod "$ns" "$release" "$SAAS_POSTGRES_STATE_MODE")"
    [ -n "$pod" ] || { _saas_log_err "Could not resolve the primary pod for release '$release'."; return 1; }

    echo "This will permanently drop database '$dbname' on release '$release'." >&2
    _saas_confirm "$yes" || return 1

    _saas_postgres_psql_run "$ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" postgres \
        "DROP DATABASE ${dbname}" >/dev/null || return 1
    _saas_log_ok "Database '$dbname' dropped."
}
