# --- 'saas minio integrate vault': the symmetric counterpart of 'saas vault integrate minio'
# (services/vault/lib/minio_integration.sh). That command deliberately never mutates the MinIO
# cluster, only ever Vault's own; applying the manifests it generates is naturally this service's
# own job, since 'saas minio' already legitimately owns and mutates ITS cluster. Direct structural
# copy of services/gitlab/lib/vault_integration.sh: it only ever reads files Vault already
# rendered and applies them here, never the reverse, and never reaches into Vault's cluster at all.

_saas_minio_integrate_vault_help() {
    cat <<'EOF'
Usage: saas minio integrate vault [OPTIONS]

Applies, into THIS MinIO release's own cluster, whatever manifests
'saas vault integrate minio' already generated: first the reviewer
ServiceAccount (so Vault's Kubernetes auth method can validate tokens
from this cluster), then, once that's done and 'saas vault integrate
minio' has been re-run to complete its side, the SecretStore/
ExternalSecret pair that lets External Secrets Operator (ESO) sync
MinIO's root credentials from Vault (so a rotation done in Vault
reaches MinIO's own '<release>-credentials' Secret; MinIO itself needs
restarting afterward to pick it up, see 'saas minio doctor').

Auto-detects which of the two is ready rather than needing a stage
flag: run it, follow whatever it prints, repeat.

Options:
      --release NAME           This minio release (default: suggested
                                if only one exists)
      --vault-release NAME    Used only to locate the manifest
                                directory Vault wrote to, by the same
                                convention it uses (default: vault)
      --from-dir DIR              Explicit override of the manifest
                                directory (skips the --vault-release
                                convention lookup)
  -y, --yes                       Don't ask for anything extra
  -h, --help                      Show this help

Examples:
  saas minio integrate vault
  saas minio integrate vault --vault-release vault
  saas minio integrate vault --from-dir /tmp/vault-manifests
EOF
}

_saas_minio_integrate_vault() {
    local release="" vault_release="vault" from_dir="" yes=false
    local args
    args=$(getopt -o yh -l release:,vault-release:,from-dir:,yes,help --name saas_minio_integrate_vault -- "$@") || {
        _saas_minio_integrate_vault_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release)         release="$2"; shift 2 ;;
            --vault-release) vault_release="$2"; shift 2 ;;
            --from-dir)        from_dir="$2"; shift 2 ;;
            -y|--yes)          yes=true; shift ;;
            -h|--help)         _saas_minio_integrate_vault_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    [ -n "$release" ] || release="$(_saas_minio_suggest_release)"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for minio release '$release'."; return 1; }
    local ns="$SAAS_MINIO_STATE_NAMESPACE"

    if [ -z "$from_dir" ]; then
        from_dir="$HOME/.local/state/saas/vault/${vault_release}/minio-integration/${release}"
    fi
    if [ ! -d "$from_dir" ] || [ -z "$(ls -A "$from_dir" 2>/dev/null)" ]; then
        _saas_log_err "No generated manifests found at '$from_dir'."
        _saas_log_err "Run 'saas vault integrate minio --vault-release $vault_release --minio-release $release' first."
        return 1
    fi

    local reviewer_manifest="$from_dir/minio-reviewer-serviceaccount.yaml"
    if [ -f "$reviewer_manifest" ]; then
        if kubectl -n vault-integration get serviceaccount "${vault_release}-vault-reviewer" >/dev/null 2>&1; then
            _saas_log_info "The reviewer ServiceAccount already exists here; skipping (nothing to apply)."
        else
            _saas_log_step "Applying the reviewer ServiceAccount…"
            kubectl apply -f "$reviewer_manifest" || return 1
            _saas_log_ok "Reviewer ServiceAccount applied. Now re-run on the Vault side:"
            _saas_log_ok "  saas vault integrate minio --vault-release $vault_release --minio-release $release"
            return 0
        fi
    fi

    local secretstore_manifest="$from_dir/minio-secretstore.yaml"
    local externalsecret_manifest="$from_dir/minio-externalsecret.yaml"
    if [ -f "$secretstore_manifest" ] && [ -f "$externalsecret_manifest" ]; then
        if ! kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
            _saas_log_err "External Secrets Operator isn't installed in this cluster (no 'externalsecrets.external-secrets.io' CRD)."
            _saas_log_err "Install ESO here first (this tool doesn't do that for you), then re-run this command."
            return 1
        fi
        _saas_log_step "Applying the SecretStore/ExternalSecret manifests…"
        kubectl -n "$ns" apply -f "$secretstore_manifest" -f "$externalsecret_manifest" || return 1
        _saas_log_ok "Applied. Check sync status with: kubectl -n $ns get externalsecret"
        _saas_log_ok "Once synced, restart MinIO to pick up any rotated password: kubectl -n $ns rollout restart deployment/$release 2>/dev/null || kubectl -n $ns rollout restart statefulset/$release"
        return 0
    fi

    _saas_log_info "Nothing new to apply yet. If you already applied the reviewer ServiceAccount, re-run 'saas vault integrate minio' on the Vault side to generate the SecretStore/ExternalSecret manifests, then run this command again."
}
