# --- 'saas gitlab integrate minio': applies, into THIS GitLab release's own cluster, the 4
# datastore Secrets 'saas minio integrate gitlab' already rendered, so a GitLab install with
# --object-storage external can use that MinIO instead of deploying its own private one. The
# symmetric counterpart of 'saas minio integrate gitlab' (services/minio/lib/gitlab_integration.sh),
# which deliberately never mutates the GitLab cluster, only ever MinIO's own; applying what it
# rendered is naturally this service's own job, since 'saas gitlab' already legitimately owns and
# mutates ITS cluster. Same shape as vault_integration.sh's apply-only half, but simpler: a single
# round trip, no reviewer-ServiceAccount/Kubernetes-auth handshake needed for handing over a set of
# static connection Secrets (see services/minio/lib/gitlab_integration.sh for why).

_saas_gitlab_integrate_minio_help() {
    cat <<'EOF'
Usage: saas gitlab integrate minio [OPTIONS]

Applies, into THIS GitLab release's own cluster, the 4 datastore
Secrets ('<release>-datastore-minio/-objectstore/-s3cfg/-registry-
storage') 'saas minio integrate gitlab' already rendered, pointing at
a shared MinIO instead of GitLab's own private one.

Run this BEFORE 'saas gitlab install --object-storage external' (that
install refuses to proceed if these Secrets aren't already present).

Options:
      --release NAME           This gitlab release (default: suggested
                                if only one exists)
      --minio-release NAME    Used only to locate the manifest
                                directory MinIO wrote to, by the same
                                convention it uses (default: minio)
      --from-dir DIR              Explicit override of the manifest
                                directory (skips the --minio-release
                                convention lookup)
  -y, --yes                       Don't ask for anything extra
  -h, --help                      Show this help

Examples:
  saas gitlab integrate minio
  saas gitlab integrate minio --minio-release minio
  saas gitlab integrate minio --from-dir /tmp/minio-manifests
EOF
}

_saas_gitlab_integrate_minio() {
    local release="" minio_release="minio" from_dir="" yes=false
    local args
    args=$(getopt -o yh -l release:,minio-release:,from-dir:,yes,help --name saas_gitlab_integrate_minio -- "$@") || {
        _saas_gitlab_integrate_minio_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release)        release="$2"; shift 2 ;;
            --minio-release) minio_release="$2"; shift 2 ;;
            --from-dir)       from_dir="$2"; shift 2 ;;
            -y|--yes)         yes=true; shift ;;
            -h|--help)        _saas_gitlab_integrate_minio_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    [ -n "$release" ] || release="$(_saas_gitlab_suggest_release)"

    local ns="$release"
    if _saas_gitlab_state_load "$release" 2>/dev/null; then
        ns="$SAAS_GITLAB_STATE_NAMESPACE"
    fi

    if [ -z "$from_dir" ]; then
        from_dir="$HOME/.local/state/saas/minio/${minio_release}/gitlab-integration/${release}"
    fi
    local secrets_manifest="$from_dir/gitlab-datastore-secrets.yaml"
    if [ ! -f "$secrets_manifest" ]; then
        _saas_log_err "No generated manifest found at '$secrets_manifest'."
        _saas_log_err "Run 'saas minio integrate gitlab --minio-release $minio_release --gitlab-release $release' first."
        return 1
    fi

    # The namespace may not exist yet (this is meant to run BEFORE 'saas gitlab install
    # --object-storage external' on a first install, same "apply before install" ordering as
    # gitlab's own initial-root-password Secret in install.sh's _saas_gitlab_provision).
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    _saas_log_step "Applying the datastore Secrets manifest…"
    kubectl -n "$ns" apply -f "$secrets_manifest" || return 1
    _saas_log_ok "Applied. Install (or reinstall) GitLab with: saas gitlab install --release $release --object-storage external"
}
