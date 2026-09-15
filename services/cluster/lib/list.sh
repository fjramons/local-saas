# --- 'saas cluster list' (alias 'ls'): lists existing kind clusters, whichever tool created them.

_saas_cluster_list_help() {
    cat <<'EOF'
Usage: saas cluster list

Lists the existing kind clusters and marks which one is the active kubectl
context (alias: ls). Shows every kind cluster on this host, regardless of
whether it was created with 'saas cluster create' or with the legacy
'kind_cluster' function (see CLAUDE.md's Design notes): both create the
same kind of real kind cluster, and this command queries 'kind'/'kubectl'
directly rather than any saas-managed inventory.

Options:
  -h, --help   Show this help

Examples:
  saas cluster list
  saas cluster ls
EOF
}

_saas_cluster_list() {
    local args
    args=$(getopt -o h -l help --name saas_cluster_list -- "$@") || { _saas_cluster_list_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -h|--help) _saas_cluster_list_help; return 0 ;;
            --)        shift; break ;;
        esac
    done

    local clusters
    clusters="$(kind get clusters -q 2>/dev/null)"
    if [ -z "$clusters" ]; then
        echo "No kind clusters exist yet."
        return 0
    fi

    local current_ctx
    current_ctx="$(kubectl config current-context 2>/dev/null || true)"

    printf "%-30s %-8s %s\n" "NAME" "ACTIVE" "CONTEXT"
    local name marker
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        marker=""
        [ "$current_ctx" = "kind-${name}" ] && marker="*"
        printf "%-30s %-8s %s\n" "$name" "$marker" "kind-${name}"
    done <<< "$clusters"
}
