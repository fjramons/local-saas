# --- Automated init/unseal for 'saas vault'. Adapted from a real production OpenBao
# deployment's unseal-sidecar idea (portable, no vendor lock-in there), but with 'bao operator
# init' itself also automated (that reference deployment left it to a human running the command
# by hand and pasting the output nowhere in particular): this repo's CLI is meant to work
# unattended too, so the root token and every Shamir key share are captured programmatically the
# moment they're produced and saved to disk (services/vault/lib/secrets.sh) before anything else
# happens, exactly like 'saas gitlab' checkpoints its own generated credentials before installing.
#
# Only a THRESHOLD-sized subset of the key shares, built from that same local file, ever makes it
# into the in-cluster 'unseal-keys' Secret; the root token never does. Documented trade-off,
# not a production-grade KMS auto-unseal replacement: anyone able to read that Secret (or exec
# into the pod while it's mounted) has master-key-equivalent access. See CLAUDE.md.

# _saas_vault_pod0 RELEASE
_saas_vault_pod0() {
    local release="$1"
    echo "$(_saas_vault_fullname "$release")-0"
}

# _saas_vault_init_ensure RELEASE NAMESPACE SHARES THRESHOLD
#
# Checks the POD'S OWN LIVE '.initialized' status first, never just "does a local keys file
# exist": verified in practice (kind, --storage-mode local-path) that a kind cluster recreated by
# 'up' does NOT actually get its old Raft data back, even though 'down' doesn't pass
# --purge-storage. kind's local-path-provisioner names each PV's on-host directory after that PV's
# own (random) UID, e.g. '<KIND_CLUSTER_STORAGE_DIR>/<name>/local-path-provisioner/pvc-<uid>_...',
# not after the stable PVC name; a fresh 'helm install' after 'up' creates a brand-new PVC/PV pair
# with a brand-new UID, so it binds to a brand-new, empty host directory. The OLD directory (with
# the old Raft/vault.db data) is still physically on disk, just permanently orphaned: nothing ever
# looks it up again. This differs from gitlab's own down/up experience only in visible effect, not
# cause: gitlab hits the exact same orphaned-PVC behavior on its PostgreSQL PVC, but a fresh, empty
# PostgreSQL re-runs its own first-boot migration and applies the SAME persisted ROOT_PASSWORD
# again, so the result looks identical to a user regardless of whether the underlying data
# survived. Vault can't paper over this the same way: Shamir key shares are cryptographically
# tied to the ONE 'bao operator init' call that produced them, so reusing old shares against a
# fresh, uninitialized Raft store can never work (confirmed live: the unseal-sidecar loops forever
# posting old shares to a store that reports 'initialized: false', never becoming unsealed).
#
# So: trust the pod's live status, not local-file presence. If already initialized (genuinely
# persisted data, or --cluster-mode existing where storage often IS reliable), reuse the saved
# keys as before. If NOT initialized despite a local keys file existing, the previous data plainly
# didn't survive: run a FRESH init and overwrite the local file with the new material, loudly
# warning that the old keys are no longer valid for this instance.
_saas_vault_init_ensure() {
    local release="$1" ns="$2" shares="$3" threshold="$4"
    local pod
    pod="$(_saas_vault_pod0 "$release")"

    local live_initialized="false"
    local status_json
    status_json="$(kubectl -n "$ns" exec "$pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao status -format=json 2>/dev/null)"
    [ -n "$status_json" ] && live_initialized="$(echo "$status_json" | jq -r '.initialized // false' 2>/dev/null)"

    if [ "$live_initialized" = "true" ] && _saas_vault_secrets_exists "$release"; then
        _saas_log_info "Reusing previously saved unseal keys for '$release' (the pod confirms it's already initialized)."
    else
        if [ "$live_initialized" != "true" ] && _saas_vault_secrets_exists "$release"; then
            _saas_log_warn "This pod reports 'initialized: false' despite having previously saved keys for '$release': the underlying storage evidently didn't survive the last down/up cycle. Generating fresh keys; the old ones are no longer valid for this instance."
        fi
        _saas_log_step "Initializing Vault ('bao operator init', ${shares} key shares / threshold ${threshold})…"
        local init_json
        init_json="$(kubectl -n "$ns" exec "$pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao operator init \
            -key-shares="$shares" -key-threshold="$threshold" -format=json 2>/dev/null)"
        [ -n "$init_json" ] || {
            _saas_log_err "'bao operator init' produced no output. Is pod '$pod' up and not already initialized?"
            return 1
        }

        local root_token shares_csv
        root_token="$(echo "$init_json" | jq -r '.root_token // empty')"
        shares_csv="$(echo "$init_json" | jq -r '(.unseal_keys_b64 // []) | join(",")')"
        [ -n "$root_token" ] || { _saas_log_err "Could not parse the root token from 'bao operator init' output."; return 1; }
        [ -n "$shares_csv" ] || { _saas_log_err "Could not parse the unseal key shares from 'bao operator init' output."; return 1; }

        # Save immediately: this is the only copy of this material anywhere, in-cluster or out.
        _saas_vault_secrets_save "$release" "$root_token" "$shares_csv" || {
            _saas_log_err "Could not save the root token/unseal keys to disk. Aborting before they're lost; do NOT re-run init blindly, check $(_saas_vault_secrets_path "$release")'s directory permissions first."
            return 1
        }
        _saas_log_ok "Root token and unseal keys saved. See 'saas vault credentials --reveal-root-token' / '--reveal-unseal-keys'."
    fi

    _saas_vault_unseal_secret_apply "$release" "$ns" "$threshold"
}

# _saas_vault_unseal_secret_apply RELEASE NAMESPACE THRESHOLD
# (Re)creates the in-cluster 'unseal-keys' Secret (and its scoped RBAC) FROM the local keys file,
# which stays the source of truth; never generates key material here. Idempotent.
_saas_vault_unseal_secret_apply() {
    local release="$1" ns="$2" threshold="$3"
    local fullname secret_name
    fullname="$(_saas_vault_fullname "$release")"
    secret_name="${release}-vault-unseal-keys"

    _saas_vault_secrets_load "$release" || { _saas_log_err "No saved unseal keys for '$release'."; return 1; }
    local csv="$SAAS_VAULT_KEYS_SHARES_CSV"
    local count
    count="$(_saas_vault_secrets_share_count "$csv")"
    [ "$count" -ge "$threshold" ] || {
        _saas_log_err "Saved unseal keys for '$release' only have $count share(s), need $threshold."
        return 1
    }

    local -a literal_args=()
    local i share
    for i in $(seq 1 "$threshold"); do
        share="$(_saas_vault_secrets_share_at "$i" "$csv")"
        literal_args+=(--from-literal="key${i}=${share}")
    done

    kubectl -n "$ns" create secret generic "$secret_name" "${literal_args[@]}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    kubectl -n "$ns" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${secret_name}-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${secret_name}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${secret_name}-reader
subjects:
  - kind: ServiceAccount
    name: ${fullname}
    namespace: ${ns}
roleRef: {kind: Role, name: ${secret_name}-reader, apiGroup: rbac.authorization.k8s.io}
EOF
}

# _saas_vault_wait_unsealed RELEASE NAMESPACE [TIMEOUT_SECONDS]
# Polls 'bao status' inside the first pod until it reports unsealed, same log_wait+poll idiom as
# gitlab's certificate-Ready wait (services/gitlab/lib/tls.sh).
_saas_vault_wait_unsealed() {
    local release="$1" ns="$2" timeout="${3:-180}"
    local pod
    pod="$(_saas_vault_pod0 "$release")"

    _saas_log_wait "Waiting for Vault to unseal (the unseal-sidecar does this automatically)…"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl -n "$ns" exec "$pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao status -format=json 2>/dev/null \
            | jq -e '.sealed == false' >/dev/null 2>&1; then
            _saas_log_ok "Vault is unsealed."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    _saas_log_err "Vault did not unseal within ${timeout}s."
    _saas_log_err "Check: kubectl -n $ns logs $pod -c unseal-sidecar"
    return 1
}

# _saas_vault_wait_ha_replicas_unsealed RELEASE NAMESPACE REPLICAS [TIMEOUT_SECONDS]
# Only meaningful for '--mode prod' (REPLICAS > 1). The chart's StatefulSet uses the default
# 'OrderedReady' pod management policy, so pod-N isn't even CREATED until pod-(N-1) reports Ready
# (unsealed) - waiting on just the LAST pod's unseal status transitively proves every earlier one
# already got there too. Without this, 'install'/'up' would declare success right after pod-0 comes
# up, silently leaving a 1-node "HA" cluster the caller has no way to know about (see CLAUDE.md).
_saas_vault_wait_ha_replicas_unsealed() {
    local release="$1" ns="$2" replicas="$3" timeout="${4:-420}"
    local fullname last_pod
    fullname="$(_saas_vault_fullname "$release")"
    last_pod="${fullname}-$((replicas - 1))"

    _saas_log_wait "Waiting for all $replicas HA replicas to join and unseal (pods start one at a time, this can take a few minutes)…"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl -n "$ns" exec "$last_pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao status -format=json 2>/dev/null \
            | jq -e '.sealed == false' >/dev/null 2>&1; then
            _saas_log_ok "All $replicas HA replicas are unsealed."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    _saas_log_err "Not all $replicas HA replicas became unsealed within ${timeout}s (last checked: '$last_pod')."
    _saas_log_err "Check: kubectl -n $ns get pods; kubectl -n $ns describe pod $last_pod; kubectl -n $ns logs $last_pod -c unseal-sidecar"
    return 1
}

_saas_vault_unseal_help() {
    cat <<'EOF'
Usage: saas vault unseal [RELEASE]

Re-applies RELEASE's saved unseal key shares to the in-cluster
'unseal-keys' Secret and waits for the unseal-sidecar to unseal every
pod. A manual escape hatch for a sealed instance; also what 'saas
vault doctor --fix' calls when it detects one.

Options:
  -h, --help   Show this help
EOF
}

_saas_vault_unseal() {
    case "${1:-}" in -h|--help) _saas_vault_unseal_help; return 0 ;; esac
    local release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    _saas_vault_unseal_secret_apply "$release" "$SAAS_VAULT_STATE_NAMESPACE" "$SAAS_VAULT_STATE_KEY_THRESHOLD" || return 1
    _saas_vault_wait_unsealed "$release" "$SAAS_VAULT_STATE_NAMESPACE"
}
