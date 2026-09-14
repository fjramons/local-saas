# --- Shared machinery for 'saas minio integrate vault' and 'saas minio integrate gitlab': a live
# self-check that this minio release is actually up, and a generic envsubst-based renderer for the
# standalone integration manifests in services/minio/values/. Mirrors the shape of
# services/vault/lib/integration_common.sh, scaled down to what minio's own integrations actually
# need (no reviewer-token/Kubernetes-auth machinery here: 'integrate gitlab' hands GitLab static
# Secret manifests, it doesn't need live cross-cluster auth trust the way ESO does).

# _saas_minio_verify_up NAMESPACE RELEASE
# True if at least one pod of this release is Ready right now.
_saas_minio_verify_up() {
    local ns="$1" release="$2"
    kubectl -n "$ns" get pods -l "app=${release}" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
        | grep -qw true
}

# _saas_minio_target_reachable CONTEXT
# Same '--request-timeout' technique as services/vault/lib/integration_common.sh's
# _saas_vault_target_reachable, for the same reason: mockable in unit tests, unlike the external
# 'timeout' command.
_saas_minio_target_reachable() {
    local ctx="$1"
    kubectl --context "$ctx" --request-timeout=10s get --raw /healthz >/dev/null 2>&1
}

# _saas_minio_render_integration_manifest SRC OUT_PATH NAME=VALUE...
_saas_minio_render_integration_manifest() {
    local src="$1" out_path="$2"; shift 2
    local -a whitelist=()
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        export "$k=$v"
        whitelist+=("\${$k}")
    done
    local IFS=' '
    envsubst "${whitelist[*]}" < "$src" > "$out_path"
}
