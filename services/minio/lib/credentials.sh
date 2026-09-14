# --- URL/credentials for 'saas minio'. Printed in plain by default, like 'saas gitlab
# credentials' (an app-level root password, not a whole-secrets-store master key the way Vault's
# root token/unseal keys are, so there's no reveal-gating precedent to follow here).

_saas_minio_credentials_help() {
    cat <<'EOF'
Usage: saas minio credentials [RELEASE] [OPTIONS]

Prints the console URL, the S3 API URL (external and in-cluster), and
the root user/password.

Options:
      --verify   Also perform a live check that the root credentials
                actually authenticate against the running instance
  -h, --help     Show this help
EOF
}

_saas_minio_credentials() {
    local release="" verify=false
    local args
    args=$(getopt -o h -l verify,help --name saas_minio_credentials -- "$@") || { _saas_minio_credentials_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --verify)  verify=true; shift ;;
            -h|--help) _saas_minio_credentials_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    local s3_domain="s3.${SAAS_MINIO_STATE_DOMAIN}"
    echo "Console URL:      https://${SAAS_MINIO_STATE_DOMAIN}"
    echo "S3 API URL:       https://${s3_domain}"
    echo "In-cluster S3:    http://${SAAS_MINIO_STATE_RELEASE}.${SAAS_MINIO_STATE_NAMESPACE}.svc.cluster.local:9000"
    echo "Root user:        $SAAS_MINIO_STATE_ROOT_USER"
    echo "Root password:    $SAAS_MINIO_STATE_ROOT_PASSWORD"

    if $verify; then
        # The quay.io/minio/minio server image doesn't bundle the 'mc' client, so this runs a
        # throwaway pod from the pinned quay.io/minio/mc image instead (same technique as bucket.sh),
        # against the in-cluster Service address, never the server pod itself. --command overrides
        # the image's own ENTRYPOINT (["mc"]); see bucket.sh's _saas_minio_mc_run for why that's
        # required, verified live against the real image.
        if kubectl -n "$SAAS_MINIO_STATE_NAMESPACE" run "${SAAS_MINIO_STATE_RELEASE}-verify-$$" --rm -i --restart=Never \
            --image="$_SAAS_MC_IMAGE" --quiet --command -- sh -c \
            "mc alias set local 'http://${SAAS_MINIO_STATE_RELEASE}.${SAAS_MINIO_STATE_NAMESPACE}.svc.cluster.local:9000' '${SAAS_MINIO_STATE_ROOT_USER}' '${SAAS_MINIO_STATE_ROOT_PASSWORD}'" >/dev/null 2>&1; then
            _saas_log_ok "--verify: the root credentials authenticate fine."
        else
            _saas_log_err "--verify: the root credentials do NOT authenticate. Try 'saas minio doctor $release --fix'."
            return 1
        fi
    fi
}
