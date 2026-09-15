# --- 'saas cluster kubeconfig': prints a cluster's kubeconfig.

_saas_cluster_kubeconfig_help() {
    cat <<'EOF'
Usage: saas cluster kubeconfig [NAME] [OPTIONS]

Prints an already-created kind cluster's kubeconfig to stdout (a wrapper
around 'kind get kubeconfig'). If NAME is omitted, a default cluster is
suggested the same way as 'delete'/'status'/'use'.

Options:
      --internal           Uses the container's internal address instead of
                            the host's external one, useful to reach the
                            cluster from inside another container/pod
      --non-interactive   Don't prompt for the name; use the suggested one
  -h, --help               Show this help

Examples:
  saas cluster kubeconfig
  saas cluster kubeconfig my-cluster > kubeconfig.yaml
  saas cluster kubeconfig my-cluster --internal
EOF
}

_saas_cluster_kubeconfig() {
    local internal=false non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local args
    args=$(getopt -o h -l internal,non-interactive,help --name saas_cluster_kubeconfig -- "$@") || {
        _saas_cluster_kubeconfig_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --internal)         internal=true; shift ;;
            --non-interactive)  non_interactive=true; shift ;;
            -h|--help)          _saas_cluster_kubeconfig_help; return 0 ;;
            --)                 shift; break ;;
        esac
    done

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    if $internal; then
        kind get kubeconfig --name "$name" --internal
    else
        kind get kubeconfig --name "$name"
    fi
}
