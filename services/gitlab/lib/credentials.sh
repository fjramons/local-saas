# --- Access credentials and URL for 'saas gitlab'.

_saas_gitlab_credentials_help() {
    cat <<'EOF'
Usage: saas gitlab credentials [RELEASE] [OPTIONS]

Prints the access URL, the 'root' user, and its initial password (the
one this same command generated and saved when RELEASE was installed).

Options:
  -h, --help   Show this help
EOF
}

_saas_gitlab_credentials() {
    local release=""
    case "${1:-}" in -h|--help) _saas_gitlab_credentials_help; return 0 ;; esac
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }

    echo ""
    echo "URL:      https://${SAAS_GITLAB_STATE_DOMAIN}"
    echo "User:     root"
    echo "Password: ${SAAS_GITLAB_STATE_ROOT_PASSWORD}"
    echo ""
    echo "(also retrievable with: kubectl -n ${SAAS_GITLAB_STATE_NAMESPACE} get secret ${release}-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo)"
    if [ "$SAAS_GITLAB_STATE_TLS" = "self-signed" ]; then
        echo ""
        echo "Self-signed TLS: the browser (and 'git'/'curl') will warn about an"
        echo "untrusted certificate, expected with --tls self-signed. To trust it:"
        echo "  kubectl -n ${SAAS_GITLAB_STATE_NAMESPACE} get secret ${release}-gitlab-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > ${release}-ca.crt"
    fi
    if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ]; then
        echo ""
        echo "SSH (clone/push/pull) without touching the host's port 22:"
        echo "  saas gitlab ssh-config ${release} --apply"
    fi
    echo ""
}
