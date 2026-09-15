# --- Shared machinery for 'saas postgres integrate vault' and 'saas postgres integrate gitlab': a
# live self-check that this postgres release is actually up, and a generic envsubst-based renderer
# for the standalone integration manifests in services/postgres/values/. Mirrors the shape of
# services/minio/lib/integration_common.sh, scaled down the same way: no reviewer-token/Kubernetes-
# auth machinery here for the gitlab integration (a single round trip, static Secrets, see
# gitlab_integration.sh); the vault integration reuses the generic two-phase helpers already in
# services/vault/lib/integration_common.sh instead of duplicating them.

# _saas_postgres_verify_up NAMESPACE RELEASE MODE
# True if the release's own primary pod is currently Ready. Resolved via backend.sh's
# _saas_postgres_primary_pod rather than a fixed label selector, since dev mode's pod carries
# 'app=<release>-postgresql' while prod mode's CNPG-managed pods carry 'cnpg.io/cluster=...'
# instead: one shared check for both, instead of a mode-dependent label.
_saas_postgres_verify_up() {
    local ns="$1" release="$2" mode="$3"
    local pod
    pod="$(_saas_postgres_primary_pod "$ns" "$release" "$mode")"
    [ -n "$pod" ] || return 1
    kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | grep -qw true
}

# _saas_postgres_target_reachable CONTEXT
# Same '--request-timeout' technique as services/vault/lib/integration_common.sh's
# _saas_vault_target_reachable, for the same reason: mockable in unit tests, unlike the external
# 'timeout' command.
_saas_postgres_target_reachable() {
    local ctx="$1"
    kubectl --context "$ctx" --request-timeout=10s get --raw /healthz >/dev/null 2>&1
}

# _saas_postgres_render_integration_manifest SRC OUT_PATH NAME=VALUE...
_saas_postgres_render_integration_manifest() {
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
