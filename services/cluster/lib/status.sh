# --- 'saas cluster status': shows a cluster's status.

_saas_cluster_status_help() {
    cat <<'EOF'
Usage: saas cluster status [NAME]

Shows a cluster's status: nodes, whether MetalLB is installed (and its IP
range), whether an ingress-controller or Gateway API is active, and the
default StorageClass. If NAME is omitted, a default cluster is suggested
the same way as 'delete'/'use'.

Options:
      --non-interactive   Don't prompt for the name; use the suggested one
  -h, --help               Show this help

Examples:
  saas cluster status
  saas cluster status my-cluster
EOF
}

_saas_cluster_status() {
    local non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local args
    args=$(getopt -o h -l non-interactive,help --name saas_cluster_status -- "$@") || {
        _saas_cluster_status_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_cluster_status_help; return 0 ;;
            --)                shift; break ;;
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

    local ctx="kind-${name}"
    echo "Cluster:    ${name}"
    echo "Context:    ${ctx}"
    echo ""
    echo "Nodes:"
    docker ps --filter "label=io.x-k8s.kind.cluster=${name}" --format '  {{.Names}}  ({{.Status}})' 2>/dev/null

    echo ""
    if kubectl --context "$ctx" -n metallb-system get deployment metallb-controller >/dev/null 2>&1; then
        local pool
        pool="$(kubectl --context "$ctx" -n metallb-system get ipaddresspools.metallb.io -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null)"
        echo "LoadBalancer (MetalLB): active${pool:+  (range: $pool)}"
    else
        echo "LoadBalancer (MetalLB): not installed"
    fi

    echo ""
    if kubectl --context "$ctx" -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
        echo "Ingress (ingress-nginx): active (hostPort 80/443)"
    elif kubectl --context "$ctx" -n envoy-gateway-system get deployment envoy-gateway >/dev/null 2>&1; then
        echo "Gateway API (Envoy Gateway): active (NodePort 30080/30443)"
    else
        echo "Ingress/Gateway API: not installed"
    fi

    echo ""
    local sc_default
    sc_default="$(kubectl --context "$ctx" get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)"
    echo "Default StorageClass: ${sc_default:-unknown}"
}
