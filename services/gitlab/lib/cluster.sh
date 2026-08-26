# --- Management of the underlying cluster for 'saas gitlab': either a kind cluster created/managed by us (via the kind_cluster function, which must already be loaded in the user's shell), or an existing cluster the active kubeconfig already points at.

_saas_gitlab_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

# _saas_gitlab_require_kind_cluster_fn
# kind_cluster is documented and maintained in the sibling bash-aliases repo; it's referenced here only by function name (never by this PC's absolute path) so as not to leak local development paths into the repo.
_saas_gitlab_require_kind_cluster_fn() {
    if ! command -v kind_cluster >/dev/null 2>&1; then
        _saas_log_err "The 'kind_cluster' function is not loaded in this shell."
        _saas_log_err "--cluster-mode kind needs it to create/manage the local cluster."
        _saas_log_err "Load 'local-cluster-functions.sh' from the bash-aliases repo before continuing."
        return 1
    fi
}

# _saas_gitlab_cluster_create KIND_NAME WORKERS STORAGE_MODE NON_INTERACTIVE YES
_saas_gitlab_cluster_create() {
    local kind_name="$1" workers="$2" storage_mode="$3" non_interactive="$4" yes="$5"
    _saas_gitlab_require_kind_cluster_fn || return 1

    local -a args=(create --name "$kind_name" --workers "$workers" \
        --storage-mode "$storage_mode" --expose-mode ingress-nginx)
    $non_interactive && args+=(--non-interactive)
    $yes && args+=(--yes)

    _saas_log_step "Creating kind cluster '$kind_name' (workers=$workers, storage-mode=$storage_mode)…"
    kind_cluster "${args[@]}"
}

# _saas_gitlab_cluster_delete KIND_NAME PURGE_STORAGE
_saas_gitlab_cluster_delete() {
    local kind_name="$1" purge="$2"
    _saas_gitlab_require_kind_cluster_fn || return 1

    local -a args=(delete "$kind_name" --yes)
    $purge && args+=(--purge-storage)

    _saas_log_step "Deleting kind cluster '$kind_name'$($purge && echo ' (with --purge-storage)')…"
    kind_cluster "${args[@]}"
}

# _saas_gitlab_cluster_use KIND_NAME
# Points kubectl at the given kind cluster's context.
_saas_gitlab_cluster_use() {
    local kind_name="$1"
    _saas_gitlab_require_kind_cluster_fn || return 1
    kind_cluster use "$kind_name" >/dev/null
}

_saas_gitlab_cluster_exists() {
    local kind_name="$1"
    _saas_gitlab_require_kind_cluster_fn || return 1
    kind get clusters -q 2>/dev/null | grep -qx "$kind_name"
}

# _saas_gitlab_cluster_patch_coredns DOMAIN [EXTRA_DOMAIN...]
# --cluster-mode kind only. A domain like '<release>.gitlab.local' (or even a real public domain whose DNS points at an IP the cluster can't reach itself on) does not resolve from INSIDE the cluster. Verified in practice: without this, both the runner registration and, above all, the 'git clone' each CI job does inside its own pod fail with "Could not resolve host", because GitLab always uses the configured public domain (global.hosts.domain) as CI_SERVER_URL, never an alternate internal URL. EXTRA_DOMAIN entries (e.g. registry.<domain>, pages.<domain>, when those features are enabled) need the same treatment: they resolve to the same ingress, just a different Host header.
#
# A 'hosts' block is added to CoreDNS's Corefile pointing every given domain at the ingress-nginx-controller ClusterIP (the same Service that already serves external traffic, so TLS/Host/routing behave exactly as they do from outside), and CoreDNS is restarted so it picks it up without waiting for the 'reload' interval. The block is delimited by marker comments and always stripped+reinserted (rather than appended only if absent) so that calling this again with a DIFFERENT domain set (e.g. --pages toggled on a later 'up') replaces the old entries instead of leaving them stale. Not touched in --cluster-mode existing (a shared cluster, not ours to reconfigure DNS on).
_saas_gitlab_cluster_patch_coredns() {
    local -a domains=("$@")
    local domain="${domains[0]}"

    local ingress_ip
    ingress_ip="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    if [ -z "$ingress_ip" ]; then
        _saas_log_warn "Could not find the ingress-nginx Service; '$domain' might not resolve inside the cluster (affects CI)."
        return 0
    fi

    local corefile
    corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)"
    if [ -z "$corefile" ]; then
        _saas_log_warn "Could not read the CoreDNS ConfigMap; '$domain' might not resolve inside the cluster (affects CI)."
        return 0
    fi

    local begin_marker="# saas-gitlab-hosts-begin" end_marker="# saas-gitlab-hosts-end"
    local stripped
    stripped="$(echo "$corefile" | sed "/^    ${begin_marker}\$/,/^    ${end_marker}\$/d")"

    local hosts_lines=""
    local d
    for d in "${domains[@]}"; do
        hosts_lines+="       ${ingress_ip} ${d}\n"
    done
    local block="    ${begin_marker}\n    hosts {\n${hosts_lines}       fallthrough\n    }\n    ${end_marker}"

    local tmp
    tmp="$(mktemp)"
    echo "$stripped" | sed "0,/^\.:53 {/{s//.:53 {\n${block}/}" > "$tmp"

    kubectl -n kube-system create configmap coredns --from-file=Corefile="$tmp" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "$tmp"
    kubectl -n kube-system rollout restart deployment coredns >/dev/null
    kubectl -n kube-system rollout status deployment coredns --timeout=60s >/dev/null
}

# _saas_gitlab_cluster_patch_coredns_pages_wildcard DOMAIN ENABLED
# --cluster-mode kind only, called only when --pages-url-mode subdomain is active. The CoreDNS
# 'hosts' plugin used by _saas_gitlab_cluster_patch_coredns can only match exact names, it has no
# wildcard support at all, so GitLab Pages' per-namespace subdomains (<namespace>.pages.<domain>,
# unknown at install time, a new one can appear at any point) need CoreDNS's 'template' plugin
# instead, matching any single-level '<label>.pages.<domain>' name and answering with an A record
# for the same ingress-nginx ClusterIP the 'hosts' block already points every other domain at, so
# TLS/Host/routing behave exactly as they do from outside.
#
# A separate block, delimited by its OWN marker comments, independent of the 'hosts' block's
# markers: always stripped and reinserted only if ENABLED=true, so toggling --pages-url-mode back
# to 'path' on a later 'up'/reinstall cleanly removes this block while leaving the 'hosts' block
# (still needed for the plain 'pages.<domain>' name) untouched. Not touched in --cluster-mode
# existing: the user is expected to have configured their own wildcard DNS entry outside this repo.
#
# The regex/answer block is assembled with plain bash string operations (no sed/awk substitution
# of content containing backslashes): both tools' 's///' replacement text special-cases backslash
# sequences in ways that differ across implementations, which would silently mangle the regex.
_saas_gitlab_cluster_patch_coredns_pages_wildcard() {
    local domain="$1" enabled="$2"

    local corefile
    corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)"
    if [ -z "$corefile" ]; then
        _saas_log_warn "Could not read the CoreDNS ConfigMap; *.pages.$domain might not resolve inside the cluster (affects Pages)."
        return 0
    fi

    local begin_marker="# saas-gitlab-pages-wildcard-begin" end_marker="# saas-gitlab-pages-wildcard-end"
    local stripped
    stripped="$(echo "$corefile" | sed "/^    ${begin_marker}\$/,/^    ${end_marker}\$/d")"

    local new_corefile="$stripped"
    if [ "$enabled" = "true" ]; then
        local ingress_ip
        ingress_ip="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
        if [ -z "$ingress_ip" ]; then
            _saas_log_warn "Could not find the ingress-nginx Service; *.pages.$domain might not resolve inside the cluster (affects Pages)."
            return 0
        fi

        local escaped_domain="${domain//./\\.}"
        local regex="^(?P<sub>[a-z0-9]([-a-z0-9]*[a-z0-9])?)\\.pages\\.${escaped_domain}\\.\$"
        local -a block=(
            "    ${begin_marker}"
            "    template IN A pages.${domain} {"
            "       match \"${regex}\""
            "       answer \"{{ .Name }} 60 IN A ${ingress_ip}\""
            "       fallthrough"
            "    }"
            "    ${end_marker}"
        )

        local -a out_lines=() line
        local inserted=false
        while IFS= read -r line; do
            out_lines+=("$line")
            case "$line" in
                .:53\ \{*)
                    if ! $inserted; then
                        out_lines+=("${block[@]}")
                        inserted=true
                    fi
                    ;;
            esac
        done <<< "$stripped"
        new_corefile="$(printf '%s\n' "${out_lines[@]}")"
    fi

    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$new_corefile" > "$tmp"
    kubectl -n kube-system create configmap coredns --from-file=Corefile="$tmp" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "$tmp"
    kubectl -n kube-system rollout restart deployment coredns >/dev/null
    kubectl -n kube-system rollout status deployment coredns --timeout=60s >/dev/null
}

# _saas_gitlab_resolve_storage_class [EXPLICIT] NON_INTERACTIVE
# Resolves the StorageClass to use in --cluster-mode existing. Never fails over a resolvable ambiguity in non-interactive mode ("sensible defaults even without interactivity"); only fails if the cluster has no StorageClass at all.
_saas_gitlab_resolve_storage_class() {
    local explicit="$1" non_interactive="$2"

    if [ -n "$explicit" ]; then
        printf '%s' "$explicit"
        return 0
    fi

    local -a classes=()
    local default_class=""
    local line name is_default
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line%% *}"
        is_default="${line#* }"
        classes+=("$name")
        [ "$is_default" = "true" ] && default_class="$name"
    done < <(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null)

    if [ "${#classes[@]}" -eq 0 ]; then
        _saas_log_err "The existing cluster has no StorageClass at all, there's no reasonable choice to make."
        _saas_log_err "Create one (or pass one with --storage-class NAME) before installing."
        return 1
    fi

    if [ -n "$default_class" ]; then
        printf '%s' "$default_class"
        return 0
    fi

    if [ "${#classes[@]}" -eq 1 ]; then
        printf '%s' "${classes[0]}"
        return 0
    fi

    local -a sorted_classes=()
    while IFS= read -r line; do
        sorted_classes+=("$line")
    done < <(printf '%s\n' "${classes[@]}" | sort)

    if $non_interactive || [ ! -t 0 ]; then
        local chosen="${sorted_classes[0]}"
        _saas_log_warn "Multiple StorageClasses and none marked default; picking '$chosen' (first alphabetically)."
        _saas_log_warn "Pin one explicitly with --storage-class NAME to not depend on this automatic choice."
        printf '%s' "$chosen"
        return 0
    fi

    _saas_prompt_menu "StorageClass to use" "${sorted_classes[0]}" false "${classes[@]}"
}
