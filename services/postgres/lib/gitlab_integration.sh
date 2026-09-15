# --- 'saas postgres integrate gitlab': creates GitLab's expected database/role on THIS postgres
# release and renders the ONE Secret GitLab's own datastore.sh would otherwise create for its
# private PostgreSQL, so 'saas gitlab install --database external' can use this postgres instead.
# See services/gitlab/lib/postgres_integration.sh for the symmetric counterpart that applies this
# manifest INTO the GitLab cluster: this file never mutates any cluster except postgres's own.
#
# Unlike Vault's integration (which needs a reviewer-ServiceAccount/Kubernetes-auth round trip so
# ESO can prove its identity to Vault before Vault hands out anything), this integration hands
# GitLab a static connection Secret: no cross-cluster auth trust is needed for that, so this is a
# SINGLE round trip (this command, then 'saas gitlab integrate postgres'), not a two-phase dance
# repeated on both sides. Deliberate simplification, not an inconsistency with the Vault pattern;
# see CLAUDE.md.

# GitLab's own datastore role/database names (services/gitlab/lib/datastore.sh's
# _saas_gitlab_datastore_psql_secret_apply/_saas_gitlab_datastore_apply). Kept as separate,
# duplicated constants here rather than sourcing gitlab's own lib file: each service only ever knows
# about the OTHER service's data shapes, never its code, same precedent as Vault's own duplicated
# knowledge of GitLab's Secret field names and MinIO's own duplicated bucket list (see CLAUDE.md).
# Must be kept in sync by hand with services/gitlab/lib/datastore.sh if these ever change.
_SAAS_POSTGRES_GITLAB_ROLE="gitlab"
_SAAS_POSTGRES_GITLAB_DATABASES=(gitlabhq_production gitlabhq_production_ci)

# _saas_postgres_host_gateway_ip
# The address a container on kind's own docker network (all kind clusters share the 'kind' network
# by default, confirmed with 'docker network ls' on this repo's own dev host) can use to reach a
# port this tool publishes to the DOCKER HOST via '-p HOSTPORT:CONTAINERPORT' (the same mechanism
# 'saas postgres install --expose' and kind's own hostPort ingress exposure already rely on): the
# 'kind' network's own gateway IP, NOT '127.0.0.1' (which inside a container means itself, not the
# host) and NOT 'host.docker.internal' (a Docker Desktop-only convenience hostname, not resolvable
# on native Linux Docker, which is what this repo targets). Falls back to the default 'bridge'
# network's gateway if the 'kind' network doesn't exist yet for some reason.
_saas_postgres_host_gateway_ip() {
    docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null \
        || docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null
}

_saas_postgres_integrate_gitlab_help() {
    cat <<'EOF'
Usage: saas postgres integrate gitlab [OPTIONS]

Creates GitLab's expected databases ('gitlabhq_production',
'gitlabhq_production_ci') and role ('gitlab') on THIS postgres
release, and renders the Secret ('<gitlab-release>-datastore-psql',
same name/keys 'saas gitlab' would create for its own private
PostgreSQL) for 'saas gitlab integrate postgres' to apply, so a GitLab
install with --database external can use this postgres instead of
deploying its own.

Must be run with THIS postgres release's cluster context active
(kubectl config current-context), same expectation as every other
'saas postgres' command: it mutates only this postgres's own cluster.

Endpoint choice: if this postgres's active context is the SAME as the
resolved GitLab context (same physical cluster, different namespace,
the realistic single-machine setup since a kind cluster's
--expose-mode ingress-nginx can't be exposed twice on one host), the
rendered Secret points GitLab at this postgres's internal Service DNS
name. If the contexts differ (genuinely separate clusters), this
release must have been installed with --expose (a genuinely separate
GitLab cluster has no other way to reach it); without --expose, this
command fails cleanly with that instruction rather than guessing at
an address.

Options:
      --postgres-release NAME  This postgres release (default:
                                suggested if only one exists)
      --gitlab-release NAME       A 'saas gitlab' release to read
                                connection info from (kubeconfig
                                context/namespace); either this or
                                --gitlab-context is required
      --gitlab-context NAME        Kubeconfig context of the target
                                GitLab cluster (overrides what
                                --gitlab-release would suggest)
      --gitlab-namespace NS        GitLab's namespace (default: read
                                from --gitlab-release's saved state, or
                                required with --gitlab-context alone)
      --output-dir DIR               Where to write the generated
                                manifest (default: see below)
  -y, --yes                         Don't ask for anything extra
  -h, --help                        Show this help

Default --output-dir:
  ~/.local/state/saas/postgres/<postgres-release>/gitlab-integration/<gitlab-release-or-context>/

Examples:
  saas postgres integrate gitlab --gitlab-release gitlab
  saas postgres integrate gitlab --gitlab-context kind-gitlab --gitlab-namespace gitlab
EOF
}

_saas_postgres_integrate_gitlab() {
    local postgres_release="" gitlab_release="" gitlab_context="" gitlab_namespace=""
    local output_dir="" yes=false

    local args
    args=$(getopt -o yh -l postgres-release:,gitlab-release:,gitlab-context:,gitlab-namespace:,output-dir:,yes,help --name saas_postgres_integrate_gitlab -- "$@") || {
        _saas_postgres_integrate_gitlab_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --postgres-release) postgres_release="$2"; shift 2 ;;
            --gitlab-release)   gitlab_release="$2"; shift 2 ;;
            --gitlab-context)   gitlab_context="$2"; shift 2 ;;
            --gitlab-namespace) gitlab_namespace="$2"; shift 2 ;;
            --output-dir)       output_dir="$2"; shift 2 ;;
            -y|--yes)           yes=true; shift ;;
            -h|--help)          _saas_postgres_integrate_gitlab_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$postgres_release" ] || postgres_release="$(_saas_postgres_suggest_release)"
    if [ -z "$gitlab_release" ] && [ -z "$gitlab_context" ]; then
        _saas_log_err "Either --gitlab-release or --gitlab-context is required."
        return 1
    fi

    # --- confirm THIS postgres release is up ---
    _saas_postgres_state_load "$postgres_release" || { _saas_log_err "No saved state for postgres release '$postgres_release'."; return 1; }
    local pg_ns="$SAAS_POSTGRES_STATE_NAMESPACE"
    _saas_postgres_verify_up "$pg_ns" "$postgres_release" "$SAAS_POSTGRES_STATE_MODE" || {
        _saas_log_err "postgres release '$postgres_release' is not reachable. Nothing else will run."
        return 1
    }

    # --- resolve the target GitLab context (read-only file read, no coupling) ---
    if [ -z "$gitlab_context" ]; then
        local gitlab_state_path="$HOME/.local/state/saas/gitlab/${gitlab_release}.env"
        [ -f "$gitlab_state_path" ] || {
            _saas_log_err "No saved state for gitlab release '$gitlab_release' ('$gitlab_state_path' not found)."
            _saas_log_err "Pass --gitlab-context explicitly if it wasn't installed with 'saas gitlab'."
            return 1
        }
        local SAAS_GITLAB_STATE_KIND_NAME="" SAAS_GITLAB_STATE_NAMESPACE="" SAAS_GITLAB_STATE_CLUSTER_MODE=""
        # shellcheck disable=SC1090
        source "$gitlab_state_path"
        if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ]; then
            gitlab_context="kind-${SAAS_GITLAB_STATE_KIND_NAME}"
        else
            _saas_log_err "gitlab release '$gitlab_release' uses --cluster-mode existing; pass --gitlab-context explicitly."
            return 1
        fi
        [ -n "$gitlab_namespace" ] || gitlab_namespace="$SAAS_GITLAB_STATE_NAMESPACE"
    fi
    [ -n "$gitlab_namespace" ] || gitlab_namespace="${gitlab_release:-gitlab}"
    local gitlab_label="${gitlab_release:-$gitlab_context}"

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/postgres/${postgres_release}/gitlab-integration/${gitlab_label}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    if ! _saas_postgres_target_reachable "$gitlab_context"; then
        _saas_log_err "Could not reach the GitLab cluster (context '$gitlab_context')."
        _saas_log_err "Nothing on the postgres side has been touched. Make sure the GitLab cluster exists and this kubeconfig context is valid, then re-run."
        return 1
    fi

    # --- endpoint choice: same-cluster (internal DNS) vs. cross-cluster (requires --expose) ---
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null)"
    local pg_host pg_port
    if [ "$current_context" = "$gitlab_context" ]; then
        pg_host="${postgres_release}-postgresql.${pg_ns}.svc.cluster.local"
        pg_port="5432"
        _saas_log_info "postgres and GitLab share the same cluster context ('$current_context'): using this postgres's internal Service address."
    elif [ "${SAAS_POSTGRES_STATE_EXPOSE:-false}" = "true" ]; then
        pg_host="$(_saas_postgres_host_gateway_ip)"
        pg_port="$SAAS_POSTGRES_STATE_HOST_PORT"
        [ -n "$pg_host" ] || { _saas_log_err "Could not determine the docker network gateway address to reach the --expose'd port."; return 1; }
        _saas_log_warn "postgres ('$current_context') and GitLab ('$gitlab_context') are on different cluster contexts: using the --expose host port via the docker network gateway ($pg_host:$pg_port). This cross-cluster path is less tested, see README.md/CLAUDE.md."
    else
        _saas_log_err "postgres ('$current_context') and GitLab ('$gitlab_context') are on different cluster contexts, and postgres release '$postgres_release' was installed without --expose."
        _saas_log_err "A genuinely separate GitLab cluster has no other way to reach this postgres instance: reinstall with 'saas postgres install --release $postgres_release --expose' first, or run this integration with both services in the same cluster (see the same-host workaround this repo's own E2E tests use)."
        return 1
    fi

    # --- postgres-only mutation from here on: create GitLab's role/databases ---
    local pod
    pod="$(_saas_postgres_primary_pod "$pg_ns" "$postgres_release" "$SAAS_POSTGRES_STATE_MODE")"
    [ -n "$pod" ] || { _saas_log_err "Could not resolve the primary pod for release '$postgres_release'."; return 1; }

    local db
    for db in "${_SAAS_POSTGRES_GITLAB_DATABASES[@]}"; do
        _saas_log_step "Creating database '${db}' (owner: ${_SAAS_POSTGRES_GITLAB_ROLE})…"
        _saas_postgres_database_create_internal "$pg_ns" "$pod" "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" \
            "$postgres_release" "$db" "$_SAAS_POSTGRES_GITLAB_ROLE" || return 1
    done
    local gitlab_password
    gitlab_password="$(_saas_postgres_role_password "$pg_ns" "$postgres_release" "$_SAAS_POSTGRES_GITLAB_ROLE")"

    _saas_log_step "Rendering the datastore Secret manifest…"
    _saas_postgres_render_integration_manifest \
        "$_SAAS_POSTGRES_DIR/values/gitlab-datastore-psql-secret.yaml.tpl" "$output_dir/gitlab-datastore-psql-secret.yaml" \
        "SAAS_GITLAB_RELEASE=$gitlab_label" \
        "SAAS_POSTGRES_GITLAB_PASSWORD=$gitlab_password"

    {
        echo "SAAS_POSTGRES_HOST=$pg_host"
        echo "SAAS_POSTGRES_PORT=$pg_port"
    } > "$output_dir/gitlab-datastore-psql-connection.env"

    _saas_log_ok "postgres is ready to serve a database for GitLab release '$gitlab_label'."
    _saas_log_info "Apply the generated manifest in the GitLab cluster with:"
    _saas_log_info "  saas gitlab integrate postgres --release $gitlab_label --postgres-release $postgres_release"
}
