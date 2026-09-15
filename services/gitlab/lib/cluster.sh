# --- Management of the underlying cluster for 'saas gitlab': either a kind cluster created/managed by us (via 'saas cluster', or the legacy 'kind_cluster' function if USE_KIND_CLUSTER_FUNCTION=true, see the shared _saas_cluster_backend_* in lib/common.sh), or an existing cluster the active kubeconfig already points at.

_saas_gitlab_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

_saas_gitlab_cluster_create() { _saas_cluster_backend_create "$@"; }
_saas_gitlab_cluster_delete() { _saas_cluster_backend_delete "$@"; }
_saas_gitlab_cluster_use()    { _saas_cluster_backend_use "$@"; }
_saas_gitlab_cluster_exists() { _saas_cluster_backend_exists "$@"; }

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

# _saas_gitlab_resolve_storage_class used to live here; it had zero gitlab-specific variation, so
# once openbao needed the exact same logic it was promoted to lib/common.sh as
# _saas_resolve_storage_class (see CLAUDE.md's Design notes). The create/delete/use/exists
# wrappers above went through the same promotion once 'saas cluster' (v1.0) replaced kind_cluster
# as the default backend and vault/minio needed the exact same USE_KIND_CLUSTER_FUNCTION-gated
# logic: they're now thin calls to the shared _saas_cluster_backend_* functions in lib/common.sh.
