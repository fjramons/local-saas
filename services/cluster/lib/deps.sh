# --- Dependency checks for 'saas cluster' (kind/docker/kubectl always; helm/envsubst/jq only when MetalLB, NFS storage, or an ingress/Gateway API install is involved).

_saas_cluster_check_deps() {
    local mode="${1:-core}"
    local -a missing=()

    command -v kind >/dev/null 2>&1    || missing+=("kind (https://kind.sigs.k8s.io/docs/user/quick-start/)")
    command -v docker >/dev/null 2>&1  || missing+=("docker")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")

    if [ "$mode" = "full" ]; then
        command -v helm >/dev/null 2>&1     || missing+=("helm")
        command -v envsubst >/dev/null 2>&1 || missing+=("envsubst (gettext package)")
        command -v jq >/dev/null 2>&1       || missing+=("jq")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        _saas_log_err "Missing dependencies:"
        local dep
        for dep in "${missing[@]}"; do
            echo "   - $dep" >&2
        done
        return 1
    fi
}

# _saas_cluster_check_inotify
# Advisory (non-blocking) warning when the host's inotify limits are still
# Linux's defaults. Verified in practice: max_user_instances=128 (the
# default) makes creating a second kind cluster fail consistently, not
# transiently (each kind node is a systemd-in-a-container, consuming
# several inotify instances each); kind's own docs name this as the #1
# cause of startup failures with several clusters/nodes. A single cluster
# with few nodes usually still works fine with the default, so this is a
# warning, never a hard block.
_saas_cluster_check_inotify() {
    local watches instances
    watches="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
    instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"

    if [ "$instances" -lt 512 ] || [ "$watches" -lt 524288 ]; then
        _saas_log_warn "Low host inotify limits (max_user_instances=${instances}, max_user_watches=${watches})."
        echo "   With several kind clusters, or clusters with many nodes, this can make cluster" >&2
        echo "   creation fail consistently (not a transient issue). To raise them:" >&2
        echo "     sudo sysctl fs.inotify.max_user_instances=512" >&2
        echo "     sudo sysctl fs.inotify.max_user_watches=524288" >&2
        echo "   To survive reboots:" >&2
        echo "     printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 524288\n' | sudo tee /etc/sysctl.d/99-kind.conf" >&2
    fi
}
