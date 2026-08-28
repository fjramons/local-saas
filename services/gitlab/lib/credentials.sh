# --- Access credentials and URL for 'saas gitlab'.

_saas_gitlab_credentials_help() {
    cat <<'EOF'
Usage: saas gitlab credentials [RELEASE] [OPTIONS]

Prints the access URL, the 'root' user, and its initial password (the
one this same command generated and saved when RELEASE was installed).

Options:
      --verify   Check the saved root password against the live
                 instance (execs into the toolbox pod; the saved value
                 can be stale if 'root' already existed from a prior
                 install, since GitLab only applies
                 'initialRootPassword' the very first time it boots
                 with no admin user at all)
  -h, --help     Show this help
EOF
}

# _saas_gitlab_credentials_verify_root_password NAMESPACE RELEASE PASSWORD
# Prints "true"/"false" to stdout via the toolbox pod's 'gitlab-rails runner'; prints nothing (and returns 1) if the check itself couldn't run, e.g. an unreachable toolbox pod.
_saas_gitlab_credentials_verify_root_password() {
    local ns="$1" release="$2" password="$3"
    local toolbox_pod
    toolbox_pod="$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep -m1 "${release}-toolbox" | sed 's#^pod/##')"
    [ -n "$toolbox_pod" ] || return 1

    local script
    script="$(cat <<RUBY
u = User.find_by_username('root')
puts(u && u.valid_password?('${password}') ? 'true' : 'false')
RUBY
)"
    kubectl -n "$ns" exec "$toolbox_pod" -- gitlab-rails runner "$script" 2>/dev/null
}

_saas_gitlab_credentials() {
    local verify=false
    local args
    args=$(getopt -o h -l verify,help --name saas_gitlab_credentials -- "$@") || { _saas_gitlab_credentials_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --verify) verify=true; shift ;;
            -h|--help) _saas_gitlab_credentials_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }

    echo ""
    echo "URL:      https://${SAAS_GITLAB_STATE_DOMAIN}"
    echo "User:     root"
    echo "Password: ${SAAS_GITLAB_STATE_ROOT_PASSWORD}"
    echo ""
    echo "(also retrievable with: kubectl -n ${SAAS_GITLAB_STATE_NAMESPACE} get secret ${release}-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo)"
    if $verify; then
        echo ""
        local result
        result="$(_saas_gitlab_credentials_verify_root_password "$SAAS_GITLAB_STATE_NAMESPACE" "$release" "$SAAS_GITLAB_STATE_ROOT_PASSWORD")"
        case "$result" in
            true)
                _saas_log_ok "Verified: the saved root password is valid against the live instance."
                ;;
            false)
                _saas_log_warn "The saved root password does NOT match the live instance (root probably already existed from a prior install, so 'initialRootPassword' never took effect). Run 'saas gitlab doctor $release' or reset it manually."
                ;;
            *)
                _saas_log_warn "Could not verify the root password (toolbox pod unreachable?)."
                ;;
        esac
    fi
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
