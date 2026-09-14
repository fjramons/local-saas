# --- Management of the underlying cluster for 'saas minio': either a kind cluster created/managed
# by us (via the kind_cluster function, which must already be loaded in the user's shell), or an
# existing cluster the active kubeconfig already points at. Same shape as services/vault/lib/cluster.sh:
# no CoreDNS patching needed here either, MinIO's own domain is only ever used from outside the
# cluster (browsers/S3 clients), never resolved from inside a pod the way GitLab's CI jobs need to
# resolve GitLab's own domain.

_saas_minio_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

# _saas_minio_cluster_create KIND_NAME WORKERS STORAGE_MODE NON_INTERACTIVE YES
_saas_minio_cluster_create() {
    local kind_name="$1" workers="$2" storage_mode="$3" non_interactive="$4" yes="$5"
    _saas_require_kind_cluster_fn || return 1

    local -a args=(create --name "$kind_name" --workers "$workers" \
        --storage-mode "$storage_mode" --expose-mode ingress-nginx)
    $non_interactive && args+=(--non-interactive)
    $yes && args+=(--yes)

    _saas_log_step "Creating kind cluster '$kind_name' (workers=$workers, storage-mode=$storage_mode)…"
    kind_cluster "${args[@]}"
}

# _saas_minio_cluster_delete KIND_NAME PURGE_STORAGE
_saas_minio_cluster_delete() {
    local kind_name="$1" purge="$2"
    _saas_require_kind_cluster_fn || return 1

    local -a args=(delete "$kind_name" --yes)
    $purge && args+=(--purge-storage)

    _saas_log_step "Deleting kind cluster '$kind_name'$($purge && echo ' (with --purge-storage)')…"
    kind_cluster "${args[@]}"
}

# _saas_minio_cluster_use KIND_NAME
# Points kubectl at the given kind cluster's context.
_saas_minio_cluster_use() {
    local kind_name="$1"
    _saas_require_kind_cluster_fn || return 1
    kind_cluster use "$kind_name" >/dev/null
}

_saas_minio_cluster_exists() {
    local kind_name="$1"
    _saas_require_kind_cluster_fn || return 1
    kind get clusters -q 2>/dev/null | grep -qx "$kind_name"
}
