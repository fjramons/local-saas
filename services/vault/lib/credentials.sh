# --- Access credentials and URL for 'saas vault'. Deliberately narrower by default than
# services/gitlab/lib/credentials.sh: the root token and unseal keys are break-glass access to the
# whole secrets store, not one app's login, so they're never printed unless explicitly asked for
# via --reveal-root-token/--reveal-unseal-keys. Both are read from the local keys file only
# (services/vault/lib/secrets.sh), never from the cluster: the root token isn't stored
# in-cluster at all (see init.sh).

_saas_vault_credentials_help() {
    cat <<'EOF'
Usage: saas vault credentials [RELEASE] [OPTIONS]

By default prints only the URL and whether the instance is sealed/
initialized. The root token and unseal keys are break-glass access to
the entire secrets store, so they require an explicit flag to reveal.

Options:
      --reveal-root-token    Print the root token
      --reveal-unseal-keys   Print every saved Shamir unseal key share
      --verify               Check the live instance's seal/init status
                              (execs into the pod)
  -h, --help                 Show this help
EOF
}

# _saas_vault_verify_status NAMESPACE RELEASE
# Prints "sealed=<bool> initialized=<bool>" to stdout via 'bao status'; prints nothing (returns 1) if unreachable.
_saas_vault_verify_status() {
    local ns="$1" release="$2"
    local pod
    pod="$(_saas_vault_pod0 "$release")"
    local json
    json="$(kubectl -n "$ns" exec "$pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao status -format=json 2>/dev/null)"
    [ -n "$json" ] || return 1
    local sealed initialized
    sealed="$(echo "$json" | jq -r '.sealed')"
    initialized="$(echo "$json" | jq -r '.initialized')"
    [ "$sealed" != "null" ] || return 1
    echo "sealed=${sealed} initialized=${initialized}"
}

_saas_vault_credentials() {
    local reveal_root_token=false reveal_unseal_keys=false verify=false
    local args
    args=$(getopt -o h -l reveal-root-token,reveal-unseal-keys,verify,help --name saas_vault_credentials -- "$@") || { _saas_vault_credentials_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --reveal-root-token)  reveal_root_token=true; shift ;;
            --reveal-unseal-keys) reveal_unseal_keys=true; shift ;;
            --verify)              verify=true; shift ;;
            -h|--help)              _saas_vault_credentials_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }

    echo ""
    echo "URL: https://${SAAS_VAULT_STATE_DOMAIN}"
    echo ""

    if $reveal_root_token || $reveal_unseal_keys; then
        if ! _saas_vault_secrets_load "$release"; then
            _saas_log_err "No saved root token/unseal keys for '$release'."
            return 1
        fi
        $reveal_root_token && echo "Root token:  ${SAAS_VAULT_KEYS_ROOT_TOKEN}"
        if $reveal_unseal_keys; then
            echo "Unseal keys:"
            local i share
            local count
            count="$(_saas_vault_secrets_share_count "$SAAS_VAULT_KEYS_SHARES_CSV")"
            for i in $(seq 1 "$count"); do
                share="$(_saas_vault_secrets_share_at "$i" "$SAAS_VAULT_KEYS_SHARES_CSV")"
                echo "  key${i}: ${share}"
            done
        fi
        echo ""
    else
        echo "(root token and unseal keys are hidden by default; use --reveal-root-token / --reveal-unseal-keys)"
        echo ""
    fi

    if $verify; then
        local result
        if result="$(_saas_vault_verify_status "$SAAS_VAULT_STATE_NAMESPACE" "$release")"; then
            _saas_log_ok "Live status: $result"
        else
            _saas_log_warn "Could not verify the live status (pod unreachable?)."
        fi
        echo ""
    fi

    if [ "$SAAS_VAULT_STATE_TLS" = "self-signed" ]; then
        echo "Self-signed external TLS: the browser (and 'curl'/'bao') will warn about an"
        echo "untrusted certificate, expected with --tls self-signed. To trust it:"
        echo "  kubectl -n ${SAAS_VAULT_STATE_NAMESPACE} get secret ${release}-vault-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > ${release}-ca.crt"
        echo ""
    fi
}
