# --- Default-cluster suggestion for 'saas cluster' subcommands that take an optional NAME.

# _saas_cluster_default_node_image_hint
# Derives, live, from the installed kind binary, which Kubernetes version it
# uses by default when --image is omitted, and the URL of kind's own release
# notes listing which other versions that same kind version supports. Makes
# no cluster, no network call; if it can't be determined (kind not
# installed, binary not locatable, pattern not found), returns an empty
# string with no error - it's purely an informational hint, never blocking.
_saas_cluster_default_node_image_hint() {
    local kind_bin kind_ver default_tag
    kind_bin="$(command -v kind)" || return 0
    [ -f "$kind_bin" ] || return 0

    default_tag="$(grep -aoE 'kindest/node:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}' "$kind_bin" 2>/dev/null | head -n1)"
    [ -n "$default_tag" ] || return 0

    kind_ver="$(kind version 2>/dev/null | awk '{print $2}')"

    local version_only="${default_tag%%@*}"
    version_only="${version_only#kindest/node:}"

    if [ -n "$kind_ver" ]; then
        printf '%s (kind %s), other versions: https://github.com/kubernetes-sigs/kind/releases/tag/%s' \
            "$version_only" "$kind_ver" "$kind_ver"
    else
        printf '%s' "$version_only"
    fi
}

# _saas_cluster_suggest_target
# Suggests a default cluster for delete/status/use/deploy-loadbalancer when
# NAME is omitted: the only existing cluster > the active kubectl context >
# the most recently created cluster. Prints the name on stdout, or a
# warning on stderr plus return 1 if there's no cluster at all.
_saas_cluster_suggest_target() {
    local clusters
    clusters="$(kind get clusters -q 2>/dev/null)"

    if [ -z "$clusters" ]; then
        _saas_log_warn "No kind clusters exist yet. Run 'saas cluster create' first."
        return 1
    fi

    local count
    count="$(printf '%s\n' "$clusters" | grep -c .)"

    if [ "$count" -eq 1 ]; then
        printf '%s' "$clusters"
        return 0
    fi

    echo "Available clusters:" >&2
    _saas_cluster_list >&2

    local current_ctx candidate
    current_ctx="$(kubectl config current-context 2>/dev/null || true)"
    if [[ "$current_ctx" == kind-* ]]; then
        candidate="${current_ctx#kind-}"
        if printf '%s\n' "$clusters" | grep -qx "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    fi

    local newest="" newest_ts=0 name created ts
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        created="$(docker inspect -f '{{.Created}}' "${name}-control-plane" 2>/dev/null)" || continue
        ts="$(date -d "$created" +%s 2>/dev/null)" || continue
        if [ "$ts" -gt "$newest_ts" ]; then
            newest_ts="$ts"
            newest="$name"
        fi
    done <<< "$clusters"

    [ -z "$newest" ] && newest="$(printf '%s\n' "$clusters" | head -n1)"

    printf '%s' "$newest"
}
