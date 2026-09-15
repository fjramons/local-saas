# --- 'saas cluster delete': removes a local kind cluster.

_saas_cluster_delete_help() {
    cat <<'EOF'
Usage: saas cluster delete [NAME] [OPTIONS]

Deletes a local kind cluster. If NAME is omitted, a default cluster is
suggested (the only existing one, the active kubectl context's, or the
most recently created one) and confirmation is requested.

Options:
      --purge-storage    Also deletes the cluster's storage directory on
                         the host (SAAS_CLUSTER_STORAGE_DIR/NAME)
  -y, --yes               Don't ask for confirmation (unattended run)
      --non-interactive   Same as --yes only for filling in the name if
                         omitted; does NOT skip the deletion confirmation
                         (that needs an explicit -y)
  -h, --help               Show this help

Environment variables:
  SAAS_CLUSTER_STORAGE_DIR      Host storage directory (with --purge-storage)
  SAAS_CLUSTER_NON_INTERACTIVE

Examples:
  saas cluster delete
  saas cluster delete my-cluster
  saas cluster delete my-cluster --purge-storage --yes
EOF
}

_saas_cluster_delete() {
    local purge_storage=false yes=false non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local storage_dir="${SAAS_CLUSTER_STORAGE_DIR:-$HOME/.local/share/kind-cluster}"

    local args
    args=$(getopt -o yh -l purge-storage,yes,non-interactive,help --name saas_cluster_delete -- "$@") || {
        _saas_cluster_delete_help; return 1
    }
    eval set -- "$args"

    while true; do
        case "$1" in
            --purge-storage)    purge_storage=true; shift ;;
            -y|--yes)           yes=true; shift ;;
            --non-interactive)  non_interactive=true; shift ;;
            -h|--help)          _saas_cluster_delete_help; return 0 ;;
            --)                 shift; break ;;
        esac
    done
    $yes && non_interactive=true

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster to delete" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    echo ""
    echo "The following will be deleted:"
    echo "   Cluster:  ${name}  (context kind-${name})"
    $purge_storage && echo "   Storage:  ${storage_dir}/${name}  (will be removed)"
    echo ""

    _saas_confirm "$yes" || return 0

    # docker/containerd can take a while to deliver the kill signal to some
    # cluster container (confirmed in practice; the time to resolve varies
    # widely, from ~30s to several minutes), making "kind delete cluster"
    # fail on the first try. Retried in a bounded loop instead of a single
    # retry with a fixed wait. Budget: 10 attempts (~3 min of sleeps): 6
    # attempts (~2 min, the earlier value) was confirmed in practice to
    # sometimes NOT be enough - a cluster with NFS storage active took over
    # 2 minutes to release its last container, and a first pass of 6
    # attempts failed, requiring a second, full manual invocation to
    # finish deleting it.
    local delete_ok=false attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ "$attempt" -gt 1 ] && _saas_log_info "Retrying cluster deletion (attempt ${attempt}/10)..."
        if kind delete cluster --name "$name"; then
            delete_ok=true
            break
        fi
        if [ "$attempt" -lt 10 ]; then
            _saas_log_warn "Docker is taking a while to release one of the cluster's containers (normal, can take several minutes). Waiting 20s before retrying (attempt ${attempt}/10)..."
            sleep 20
        fi
    done
    if ! $delete_ok; then
        _saas_log_err "Failed to delete the cluster after several retries. Try by hand in a few minutes: kind delete cluster --name ${name}"
        return 1
    fi

    # Unlike --purge-storage (opt-in, since it protects user data), cleaning
    # up 'expose' proxies is unconditional: they hold no data at all, pure
    # L4 plumbing pointing at a cluster that no longer exists - leaving
    # them alive after 'delete' only leaves host ports hanging with no
    # benefit worth weighing.
    local expose_ids
    expose_ids="$(docker ps -aq --filter "label=kind-cluster.expose.cluster=${name}" 2>/dev/null)"
    if [ -n "$expose_ids" ]; then
        _saas_log_step "Removing $(printf '%s\n' "$expose_ids" | grep -c .) 'expose' publication(s) associated with '${name}'..."
        printf '%s\n' "$expose_ids" | xargs -r docker rm -f >/dev/null 2>&1
    fi

    local purge_failed=false
    if $purge_storage; then
        # The NFS server (--storage-mode nfs) runs in a privileged
        # container; the files it writes under the hostPath end up owned by
        # root on the host (no user-namespace remapping), so "rm -rf" as a
        # normal user can fail halfway ("Permission denied" on specific
        # files, which "rm -f" DOES propagate as a real error, unlike
        # "doesn't exist"). Managing a kind cluster should never need sudo:
        # the same docker access already needed to create/delete the
        # cluster is enough to clean up its storage too - if the normal
        # "rm" fails, the deletion is retried from inside an ephemeral
        # container, where "root" can delete any file in the bind mount
        # regardless of who owns it on the host.
        if ! rm -rf "${storage_dir:?}/${name}" 2>/dev/null; then
            # The stable version current when this was pinned (see the
            # "Pinned versions" table in CLAUDE.md): keeps this purge's
            # "docker run" from pulling in an unexpected base image update.
            docker run --rm -v "${storage_dir}:/purge" busybox:1.38.0 rm -rf "/purge/${name}" \
                || purge_failed=true
        fi
    fi

    if $purge_failed; then
        _saas_log_warn "Cluster '${name}' deleted, but not all of '${storage_dir}/${name}' could be purged."
        return 1
    fi

    _saas_log_ok "Cluster '${name}' deleted."
}
