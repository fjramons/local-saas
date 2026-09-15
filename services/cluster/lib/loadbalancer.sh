# --- 'saas cluster deploy-loadbalancer' (alias 'lb'): installs/reinstalls MetalLB on an already existing cluster.

_saas_cluster_deploy_loadbalancer_help() {
    cat <<'EOF'
Usage: saas cluster deploy-loadbalancer [NAME] [OPTIONS]

Installs (or reinstalls) MetalLB on an already existing cluster, for
example one created with --no-loadbalancer (alias: lb). If NAME is
omitted, a default cluster is suggested the same way as
'delete'/'status'/'use'.

Options:
      --lb-range START-END   Manual IP range, instead of computing it
                              automatically
  -y, --yes                    Don't prompt for the cluster name
      --non-interactive        Same as --yes for filling in the name
  -h, --help                    Show this help

Examples:
  saas cluster deploy-loadbalancer my-cluster
  saas cluster lb my-cluster --lb-range 172.19.0.200-172.19.0.209
EOF
}

_saas_cluster_deploy_loadbalancer() {
    local lb_range="" yes=false non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"

    local args
    args=$(getopt -o yh -l lb-range:,yes,non-interactive,help --name saas_cluster_deploy_loadbalancer -- "$@") || {
        _saas_cluster_deploy_loadbalancer_help; return 1
    }
    eval set -- "$args"

    while true; do
        case "$1" in
            --lb-range)         lb_range="$2"; shift 2 ;;
            -y|--yes)           yes=true; shift ;;
            --non-interactive)  non_interactive=true; shift ;;
            -h|--help)          _saas_cluster_deploy_loadbalancer_help; return 0 ;;
            --)                 shift; break ;;
        esac
    done
    $yes && non_interactive=true

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    _saas_cluster_install_metallb "$name" "$lb_range"
}
