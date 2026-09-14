# --- Management of the underlying cluster for 'saas vault': either a kind cluster created/
# managed by us (via the kind_cluster function, which must already be loaded in the user's shell,
# see the shared _saas_require_kind_cluster_fn in lib/common.sh), or an existing cluster the active
# kubeconfig already points at. Unlike services/gitlab/lib/cluster.sh, no CoreDNS patching is
# needed here: gitlab needs it because CI jobs running INSIDE its own cluster must resolve
# gitlab's own public domain; nothing running inside Vault's own cluster needs to resolve
# Vault's own external domain, so there's nothing to patch.

_saas_vault_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

# _saas_vault_cluster_create KIND_NAME WORKERS STORAGE_MODE NON_INTERACTIVE YES
_saas_vault_cluster_create() {
    local kind_name="$1" workers="$2" storage_mode="$3" non_interactive="$4" yes="$5"
    _saas_require_kind_cluster_fn || return 1

    local -a args=(create --name "$kind_name" --workers "$workers" \
        --storage-mode "$storage_mode" --expose-mode ingress-nginx)
    $non_interactive && args+=(--non-interactive)
    $yes && args+=(--yes)

    _saas_log_step "Creating kind cluster '$kind_name' (workers=$workers, storage-mode=$storage_mode)…"
    kind_cluster "${args[@]}"
}

# _saas_vault_cluster_delete KIND_NAME PURGE_STORAGE
_saas_vault_cluster_delete() {
    local kind_name="$1" purge="$2"
    _saas_require_kind_cluster_fn || return 1

    local -a args=(delete "$kind_name" --yes)
    $purge && args+=(--purge-storage)

    _saas_log_step "Deleting kind cluster '$kind_name'$($purge && echo ' (with --purge-storage)')…"
    kind_cluster "${args[@]}"
}

# _saas_vault_cluster_use KIND_NAME
# Points kubectl at the given kind cluster's context.
_saas_vault_cluster_use() {
    local kind_name="$1"
    _saas_require_kind_cluster_fn || return 1
    kind_cluster use "$kind_name" >/dev/null
}

_saas_vault_cluster_exists() {
    local kind_name="$1"
    _saas_require_kind_cluster_fn || return 1
    kind get clusters -q 2>/dev/null | grep -qx "$kind_name"
}
