# --- 'saas gitlab integrate postgres': applies, into THIS GitLab release's own cluster, the
# Secret 'saas postgres integrate gitlab' already rendered, and folds the connection host/port it
# also wrote into gitlab's own saved state, so a GitLab install with --database external can use
# that postgres instead of deploying its own private one. The symmetric counterpart of 'saas
# postgres integrate gitlab' (services/postgres/lib/gitlab_integration.sh), which deliberately
# never mutates the GitLab cluster, only ever postgres's own; applying what it rendered is
# naturally this service's own job, since 'saas gitlab' already legitimately owns and mutates ITS
# cluster. Same shape as minio_integration.sh's apply-only half, but simpler: a single round trip,
# no reviewer-ServiceAccount/Kubernetes-auth handshake needed for handing over a static connection
# Secret (see services/postgres/lib/gitlab_integration.sh for why).

_saas_gitlab_integrate_postgres_help() {
    cat <<'EOF'
Usage: saas gitlab integrate postgres [OPTIONS]

Applies, into THIS GitLab release's own cluster, the Secret
('<release>-datastore-psql') 'saas postgres integrate gitlab' already
rendered, pointing at a shared PostgreSQL instead of GitLab's own
private one, and saves the connection host/port into gitlab's own
state (needed later as a Helm value, not something embeddable inside
the Secret itself).

Run this BEFORE 'saas gitlab install --database external' (that
install refuses to proceed if the Secret isn't already present).

Options:
      --release NAME           This gitlab release (default: suggested
                                if only one exists)
      --postgres-release NAME    Used only to locate the manifest
                                directory postgres wrote to, by the
                                same convention it uses (default:
                                postgres)
      --from-dir DIR                Explicit override of the manifest
                                directory (skips the --postgres-release
                                convention lookup)
  -y, --yes                        Don't ask for anything extra
  -h, --help                       Show this help

Examples:
  saas gitlab integrate postgres
  saas gitlab integrate postgres --postgres-release postgres
  saas gitlab integrate postgres --from-dir /tmp/postgres-manifests
EOF
}

_saas_gitlab_integrate_postgres() {
    local release="" postgres_release="postgres" from_dir="" yes=false
    local args
    args=$(getopt -o yh -l release:,postgres-release:,from-dir:,yes,help --name saas_gitlab_integrate_postgres -- "$@") || {
        _saas_gitlab_integrate_postgres_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release)          release="$2"; shift 2 ;;
            --postgres-release) postgres_release="$2"; shift 2 ;;
            --from-dir)         from_dir="$2"; shift 2 ;;
            -y|--yes)           yes=true; shift ;;
            -h|--help)          _saas_gitlab_integrate_postgres_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    [ -n "$release" ] || release="$(_saas_gitlab_suggest_release)"

    local ns="$release"
    if _saas_gitlab_state_load "$release" 2>/dev/null; then
        ns="$SAAS_GITLAB_STATE_NAMESPACE"
    fi

    if [ -z "$from_dir" ]; then
        from_dir="$HOME/.local/state/saas/postgres/${postgres_release}/gitlab-integration/${release}"
    fi
    local secret_manifest="$from_dir/gitlab-datastore-psql-secret.yaml"
    local connection_env="$from_dir/gitlab-datastore-psql-connection.env"
    if [ ! -f "$secret_manifest" ] || [ ! -f "$connection_env" ]; then
        _saas_log_err "No generated manifest found at '$from_dir'."
        _saas_log_err "Run 'saas postgres integrate gitlab --postgres-release $postgres_release --gitlab-release $release' first."
        return 1
    fi

    # The namespace may not exist yet (this is meant to run BEFORE 'saas gitlab install
    # --database external' on a first install, same "apply before install" ordering as gitlab's
    # own initial-root-password Secret in install.sh's _saas_gitlab_provision).
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    _saas_log_step "Applying the datastore Secret…"
    kubectl -n "$ns" apply -f "$secret_manifest" || return 1

    local SAAS_POSTGRES_HOST="" SAAS_POSTGRES_PORT=""
    # shellcheck disable=SC1090
    source "$connection_env"
    [ -n "$SAAS_POSTGRES_HOST" ] || { _saas_log_err "'$connection_env' didn't contain a SAAS_POSTGRES_HOST."; return 1; }

    if _saas_gitlab_state_exists "$release"; then
        _saas_gitlab_state_save_key "$release" "DATABASE_HOST" "$SAAS_POSTGRES_HOST"
        _saas_gitlab_state_save_key "$release" "DATABASE_PORT" "$SAAS_POSTGRES_PORT"
    else
        # No saved state yet (first install, database-external from the very start): stash the
        # host/port under the same namespace-scoped state directory anyway, keyed by RELEASE, so
        # the upcoming 'saas gitlab install --database external' can read it back via a plain
        # state load. A minimal state file with just these three keys is enough for
        # _saas_gitlab_state_load to succeed; install.sh's own flow fills in everything else.
        _saas_gitlab_state_save "$release" "RELEASE=$release" "NAMESPACE=$ns" \
            "DATABASE_HOST=$SAAS_POSTGRES_HOST" "DATABASE_PORT=$SAAS_POSTGRES_PORT"
    fi

    _saas_log_ok "Applied. Install (or reinstall) GitLab with: saas gitlab install --release $release --database external"
}
