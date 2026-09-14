# --- 'saas minio integrate gitlab': creates GitLab's expected bucket set on THIS MinIO release
# and renders the 4 Secrets GitLab's own datastore.sh would otherwise create for its private
# MinIO, so 'saas gitlab install --object-storage external' can use this MinIO instead. See
# services/gitlab/lib/minio_integration.sh for the symmetric counterpart that applies these
# manifests INTO the GitLab cluster: this file never mutates any cluster except MinIO's own.
#
# Unlike Vault's integrations (which need a reviewer-ServiceAccount/Kubernetes-auth round trip so
# ESO can prove its identity to Vault before Vault hands out anything), this integration hands
# GitLab a set of static connection Secrets: no cross-cluster auth trust is needed for that, so
# this is a SINGLE round trip (this command, then 'saas gitlab integrate minio'), not a two-phase
# dance repeated on both sides. Deliberate simplification, not an inconsistency with the Vault
# pattern; see CLAUDE.md.

# GitLab's own bucket list (services/gitlab/lib/datastore.sh's _SAAS_GITLAB_MINIO_BUCKETS). Kept as
# a separate, duplicated constant here rather than sourcing gitlab's own lib file: each service
# only ever knows about the OTHER service's data shapes, never its code, same precedent as Vault's
# own duplicated knowledge of GitLab's Secret field names (see CLAUDE.md). Must be kept in sync by
# hand with services/gitlab/lib/datastore.sh's _SAAS_GITLAB_MINIO_BUCKETS if that list ever changes.
_SAAS_MINIO_GITLAB_BUCKETS=(
    registry git-lfs gitlab-artifacts gitlab-uploads gitlab-packages
    gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files
    gitlab-agent-plan-content gitlab-ci-catalog-bundles
    gitlab-dependency-proxy gitlab-backups gitlab-pages
)

_saas_minio_integrate_gitlab_help() {
    cat <<'EOF'
Usage: saas minio integrate gitlab [OPTIONS]

Creates GitLab's expected bucket set on THIS MinIO release and renders
the 4 Secrets ('<gitlab-release>-datastore-minio/-objectstore/-s3cfg/
-registry-storage', same names/keys 'saas gitlab' would create for its
own private MinIO) for 'saas gitlab integrate minio' to apply, so a
GitLab install with --object-storage external can use this MinIO
instead of deploying its own.

Must be run with THIS MinIO release's cluster context active
(kubectl config current-context), same expectation as every other
'saas minio' command: it mutates only this MinIO's own cluster.

Endpoint choice: if this MinIO's active context is the SAME as the
resolved GitLab context (same physical cluster, different namespace,
the realistic single-machine setup since a kind cluster's
--expose-mode ingress-nginx can't be exposed twice on one host), the
rendered Secrets point GitLab at MinIO's plain internal Service DNS
name, no TLS involved. If the contexts differ (genuinely separate
clusters), they point at MinIO's external HTTPS ingress endpoint
instead - a less-tested path: no CA-trust injection into GitLab's
toolbox/registry pods is implemented for a self-signed certificate in
this case, see README.md/CLAUDE.md.

Options:
      --minio-release NAME     This MinIO release (default: suggested
                                if only one exists)
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
  ~/.local/state/saas/minio/<minio-release>/gitlab-integration/<gitlab-release-or-context>/

Examples:
  saas minio integrate gitlab --gitlab-release gitlab
  saas minio integrate gitlab --gitlab-context kind-gitlab --gitlab-namespace gitlab
EOF
}

_saas_minio_integrate_gitlab() {
    local minio_release="" gitlab_release="" gitlab_context="" gitlab_namespace=""
    local output_dir="" yes=false

    local args
    args=$(getopt -o yh -l minio-release:,gitlab-release:,gitlab-context:,gitlab-namespace:,output-dir:,yes,help --name saas_minio_integrate_gitlab -- "$@") || {
        _saas_minio_integrate_gitlab_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --minio-release)   minio_release="$2"; shift 2 ;;
            --gitlab-release)  gitlab_release="$2"; shift 2 ;;
            --gitlab-context)  gitlab_context="$2"; shift 2 ;;
            --gitlab-namespace) gitlab_namespace="$2"; shift 2 ;;
            --output-dir)      output_dir="$2"; shift 2 ;;
            -y|--yes)          yes=true; shift ;;
            -h|--help)         _saas_minio_integrate_gitlab_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$minio_release" ] || minio_release="$(_saas_minio_suggest_release)"
    if [ -z "$gitlab_release" ] && [ -z "$gitlab_context" ]; then
        _saas_log_err "Either --gitlab-release or --gitlab-context is required."
        return 1
    fi

    # --- confirm THIS MinIO release is up ---
    _saas_minio_state_load "$minio_release" || { _saas_log_err "No saved state for minio release '$minio_release'."; return 1; }
    local minio_ns="$SAAS_MINIO_STATE_NAMESPACE"
    _saas_minio_verify_up "$minio_ns" "$minio_release" || {
        _saas_log_err "MinIO release '$minio_release' is not reachable. Nothing else will run."
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

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/minio/${minio_release}/gitlab-integration/${gitlab_label}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    if ! _saas_minio_target_reachable "$gitlab_context"; then
        _saas_log_err "Could not reach the GitLab cluster (context '$gitlab_context')."
        _saas_log_err "Nothing on the MinIO side has been touched. Make sure the GitLab cluster exists and this kubeconfig context is valid, then re-run."
        return 1
    fi

    # --- endpoint choice: same-cluster (internal DNS, no TLS) vs. cross-cluster (external HTTPS) ---
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null)"
    local minio_host minio_endpoint minio_secure minio_use_https
    if [ "$current_context" = "$gitlab_context" ]; then
        minio_host="${minio_release}.${minio_ns}.svc.cluster.local:9000"
        minio_endpoint="http://${minio_host}"
        minio_secure="false"
        minio_use_https="False"
        _saas_log_info "MinIO and GitLab share the same cluster context ('$current_context'): using MinIO's internal Service address, plain HTTP."
    else
        minio_host="s3.${SAAS_MINIO_STATE_DOMAIN}:443"
        minio_endpoint="https://s3.${SAAS_MINIO_STATE_DOMAIN}"
        minio_secure="true"
        minio_use_https="True"
        _saas_log_warn "MinIO ('$current_context') and GitLab ('$gitlab_context') are on different cluster contexts: using MinIO's external HTTPS endpoint."
        _saas_log_warn "This cross-cluster path is less tested: no CA-trust injection for a self-signed MinIO certificate is implemented, see README.md/CLAUDE.md. Use --tls letsencrypt on 'saas minio install' to avoid this entirely."
    fi

    # --- MinIO-only mutation from here on: create GitLab's bucket set ---
    _saas_log_step "Creating GitLab's ${#_SAAS_MINIO_GITLAB_BUCKETS[@]} expected bucket(s) on this MinIO…"
    _saas_minio_init_buckets "$minio_ns" "$minio_release" "${_SAAS_MINIO_GITLAB_BUCKETS[@]}" || return 1

    _saas_log_step "Rendering the datastore Secrets manifest…"
    _saas_minio_render_integration_manifest \
        "$_SAAS_MINIO_DIR/values/gitlab-datastore-secrets.yaml.tpl" "$output_dir/gitlab-datastore-secrets.yaml" \
        "SAAS_GITLAB_RELEASE=$gitlab_label" \
        "SAAS_MINIO_ROOT_USER=$SAAS_MINIO_STATE_ROOT_USER" \
        "SAAS_MINIO_ROOT_PASSWORD=$SAAS_MINIO_STATE_ROOT_PASSWORD" \
        "SAAS_MINIO_HOST=$minio_host" \
        "SAAS_MINIO_ENDPOINT=$minio_endpoint" \
        "SAAS_MINIO_SECURE=$minio_secure" \
        "SAAS_MINIO_USE_HTTPS=$minio_use_https"

    _saas_log_ok "MinIO is ready to serve object storage for GitLab release '$gitlab_label'."
    _saas_log_info "Apply the generated manifest in the GitLab cluster with:"
    _saas_log_info "  saas gitlab integrate minio --release $gitlab_label --minio-release $minio_release --from-dir $output_dir"
}
