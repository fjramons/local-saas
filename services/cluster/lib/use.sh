# --- 'saas cluster use' (alias 'switch'): switches the active kubectl context.

_saas_cluster_use_help() {
    cat <<'EOF'
Usage: saas cluster use [NAME]

Switches the active kubectl context to a kind cluster's (alias: switch). If
NAME is omitted, a default cluster is suggested the same way as
'delete'/'status'.

Options:
      --non-interactive   Don't prompt for the name; use the suggested one
  -h, --help               Show this help

Examples:
  saas cluster use my-cluster
  saas cluster switch
EOF
}

_saas_cluster_use() {
    local non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local args
    args=$(getopt -o h -l non-interactive,help --name saas_cluster_use -- "$@") || {
        _saas_cluster_use_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_cluster_use_help; return 0 ;;
            --)                shift; break ;;
        esac
    done

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    kubectl config use-context "kind-${name}" \
        && _saas_log_ok "Active context: kind-${name}" \
        || { _saas_log_err "Could not switch to context 'kind-${name}'. Does the cluster exist?"; return 1; }
}
