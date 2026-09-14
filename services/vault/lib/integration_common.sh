# --- Shared machinery for 'saas vault integrate gitlab' and 'saas vault integrate eso':
# running 'bao' commands against THIS release (via 'kubectl exec', using the saved root token,
# never anything printed to the user unless they asked for it with 'credentials
# --reveal-root-token'), and read-only inspection of a TARGET cluster (a different kubeconfig
# context) that never mutates it - only 'saas gitlab integrate vault' (the symmetric counterpart
# in services/gitlab/lib/vault_integration.sh) is allowed to write into that other cluster.

# _saas_vault_bao_exec RELEASE NAMESPACE ARGS...
# Runs 'bao ARGS...' inside RELEASE's own pod, authenticated as root (the only place the root
# token is ever used programmatically).
_saas_vault_bao_exec() {
    local release="$1" ns="$2"; shift 2
    _saas_vault_secrets_load "$release" || { _saas_log_err "No saved root token for '$release'. Is it installed and initialized?"; return 1; }
    local pod
    pod="$(_saas_vault_pod0 "$release")"
    kubectl -n "$ns" exec "$pod" -c openbao -- env \
        BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" \
        BAO_TOKEN="$SAAS_VAULT_KEYS_ROOT_TOKEN" \
        bao "$@"
}

# _saas_vault_bao_exec_stdin RELEASE NAMESPACE ARGS... < stdin
# Same as above but forwards stdin (kubectl exec -i), for 'bao write PATH -'/'bao policy write NAME -'
# style commands that take their payload as a JSON/HCL body on stdin instead of key=value argv
# pairs (needed for multi-line values like a PEM CA cert, which argv escaping handles poorly).
_saas_vault_bao_exec_stdin() {
    local release="$1" ns="$2"; shift 2
    _saas_vault_secrets_load "$release" || { _saas_log_err "No saved root token for '$release'. Is it installed and initialized?"; return 1; }
    local pod
    pod="$(_saas_vault_pod0 "$release")"
    kubectl -n "$ns" exec -i "$pod" -c openbao -- env \
        BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" \
        BAO_TOKEN="$SAAS_VAULT_KEYS_ROOT_TOKEN" \
        bao "$@"
}

# _saas_vault_kv_engine_ensure RELEASE NAMESPACE PATH
_saas_vault_kv_engine_ensure() {
    local release="$1" ns="$2" path="$3"
    if _saas_vault_bao_exec "$release" "$ns" secrets list -format=json 2>/dev/null | jq -e --arg p "${path}/" 'has($p)' >/dev/null 2>&1; then
        _saas_log_info "KV engine already mounted at '$path'."
        return 0
    fi
    _saas_log_step "Enabling the KV v2 secrets engine at '$path'…"
    _saas_vault_bao_exec "$release" "$ns" secrets enable -path="$path" -version=2 kv
}

# _saas_vault_k8s_auth_ensure RELEASE NAMESPACE
_saas_vault_k8s_auth_ensure() {
    local release="$1" ns="$2"
    if _saas_vault_bao_exec "$release" "$ns" auth list -format=json 2>/dev/null | jq -e 'has("kubernetes/")' >/dev/null 2>&1; then
        _saas_log_info "Kubernetes auth method already enabled."
        return 0
    fi
    _saas_log_step "Enabling the Kubernetes auth method…"
    _saas_vault_bao_exec "$release" "$ns" auth enable kubernetes
}

# _saas_vault_k8s_auth_configure RELEASE NAMESPACE K8S_HOST K8S_CA_CERT REVIEWER_JWT
_saas_vault_k8s_auth_configure() {
    local release="$1" ns="$2" k8s_host="$3" k8s_ca_cert="$4" reviewer_jwt="$5"
    jq -n --arg host "$k8s_host" --arg ca "$k8s_ca_cert" --arg jwt "$reviewer_jwt" \
        '{kubernetes_host: $host, kubernetes_ca_cert: $ca, token_reviewer_jwt: $jwt}' \
        | _saas_vault_bao_exec_stdin "$release" "$ns" write auth/kubernetes/config -
}

# _saas_vault_policy_write RELEASE NAMESPACE NAME HCL
_saas_vault_policy_write() {
    local release="$1" ns="$2" name="$3" hcl="$4"
    echo "$hcl" | _saas_vault_bao_exec_stdin "$release" "$ns" policy write "$name" -
}

# _saas_vault_k8s_role_write RELEASE NAMESPACE ROLE SA_NAME SA_NAMESPACE POLICY
_saas_vault_k8s_role_write() {
    local release="$1" ns="$2" role="$3" sa_name="$4" sa_ns="$5" policy="$6"
    _saas_vault_bao_exec "$release" "$ns" write "auth/kubernetes/role/${role}" \
        "bound_service_account_names=${sa_name}" \
        "bound_service_account_namespaces=${sa_ns}" \
        "policies=${policy}" "ttl=1h"
}

# _saas_vault_kv_put RELEASE NAMESPACE MOUNT PATH KEY=VALUE...
_saas_vault_kv_put() {
    local release="$1" ns="$2" mount="$3" path="$4"; shift 4
    _saas_vault_bao_exec "$release" "$ns" kv put -mount="$mount" "$path" "$@"
}

# _saas_vault_ca_bundle_b64 NAMESPACE RELEASE
# Base64 of the EXTERNAL certificate's tls.crt (already base64 as stored in the Secret's .data).
# Used as the extra trust anchor ESO's SecretStore needs to verify Vault's ingress: with
# --tls self-signed this IS the (self-signed) root, so it's required for verification to succeed
# at all; with --tls letsencrypt it's a real leaf cert already covered by the system's default CA
# pool, so adding it here is harmless and redundant rather than wrong, keeping this one code path
# correct for both external TLS modes without needing to special-case letsencrypt.
_saas_vault_ca_bundle_b64() {
    local ns="$1" release="$2"
    kubectl -n "$ns" get secret "${release}-vault-tls" -o jsonpath='{.data.tls\.crt}' 2>/dev/null
}

# --- Read-only inspection of a TARGET cluster (a different kubeconfig context). Never mutates it. ---

# _saas_vault_target_reachable CONTEXT
# Uses kubectl's own --request-timeout (not the external 'timeout' command): 'timeout CMD' execs
# CMD via PATH directly, which would bypass a mocked 'kubectl' shell function entirely in tests
# (and could invoke a REAL kubectl if one happens to be on PATH), so it can't be used to bound a
# call meant to be mockable/controllable like this one.
_saas_vault_target_reachable() {
    local ctx="$1"
    kubectl --context "$ctx" --request-timeout=10s get --raw /healthz >/dev/null 2>&1
}

# _saas_vault_target_api_server CONTEXT
_saas_vault_target_api_server() {
    local ctx="$1"
    kubectl --context "$ctx" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
}

# _saas_vault_target_reviewer_secret_exists CONTEXT VAULT_RELEASE
_saas_vault_target_reviewer_secret_exists() {
    local ctx="$1" vault_release="$2"
    kubectl --context "$ctx" -n vault-integration get secret "${vault_release}-vault-reviewer-token" >/dev/null 2>&1
}

_saas_vault_target_reviewer_token() {
    local ctx="$1" vault_release="$2"
    kubectl --context "$ctx" -n vault-integration get secret "${vault_release}-vault-reviewer-token" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null
}

_saas_vault_target_reviewer_ca() {
    local ctx="$1" vault_release="$2"
    kubectl --context "$ctx" -n vault-integration get secret "${vault_release}-vault-reviewer-token" \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null
}

# _saas_vault_render_integration_manifest SRC OUT_PATH NAME=VALUE...
# Generic envsubst-based renderer for the standalone integration manifests (services/vault/values/
# gitlab-*.yaml.tpl, eso-*.yaml.tpl), which have their own, per-call variable sets, distinct from
# the fixed Helm-values variable set services/vault/lib/install.sh's renderer uses.
_saas_vault_render_integration_manifest() {
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
