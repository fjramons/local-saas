#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas vault: validators, state/secrets roundtrip,
# fullname resolution, unseal-key share helpers, and - critically - the order-independence
# guarantee of 'saas vault integrate gitlab' and its gitlab-side counterpart. Same mocking
# pattern as tests/gitlab/unit/test-argparse-values.sh (shadow kubectl/helm/kind_cluster by
# defining same-named bash functions). Does not replace the real E2E suite (tests/vault/e2e/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Normally set by services/vault/vault.sh (not sourced here, only the individual lib files
# are, same as tests/gitlab/unit/test-argparse-values.sh does for _SAAS_GITLAB_DIR); the
# integration functions need it to locate services/vault/values/*.yaml.tpl.
_SAAS_VAULT_DIR="$REPO_ROOT/services/vault"
declare -a RESULTS=()

pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

# kind_cluster isn't needed for these tests (no real cluster is touched), but the shared
# _saas_require_kind_cluster_fn (lib/common.sh) only checks 'command -v kind_cluster'.
kind_cluster() { :; }

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/services/vault/lib/state.sh"
source "$REPO_ROOT/services/vault/lib/secrets.sh"
source "$REPO_ROOT/services/vault/lib/cluster.sh"
source "$REPO_ROOT/services/vault/lib/versions.sh"
source "$REPO_ROOT/services/vault/lib/operators.sh"
source "$REPO_ROOT/services/vault/lib/tls.sh"
source "$REPO_ROOT/services/vault/lib/init.sh"
source "$REPO_ROOT/services/vault/lib/install.sh"
source "$REPO_ROOT/services/vault/lib/credentials.sh"
source "$REPO_ROOT/services/vault/lib/doctor.sh"
source "$REPO_ROOT/services/vault/lib/integration_common.sh"
source "$REPO_ROOT/services/vault/lib/gitlab_integration.sh"
source "$REPO_ROOT/services/vault/lib/eso_integration.sh"
source "$REPO_ROOT/services/gitlab/lib/state.sh"
source "$REPO_ROOT/services/gitlab/lib/vault_integration.sh"

export SAAS_VAULT_STATE_DIR
SAAS_VAULT_STATE_DIR="$(mktemp -d)"
export SAAS_GITLAB_STATE_DIR
SAAS_GITLAB_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$SAAS_VAULT_STATE_DIR" "$SAAS_GITLAB_STATE_DIR"' EXIT

# ------------------------------------------------------------------
# Pure validators
# ------------------------------------------------------------------
_saas_vault_valid_cluster_mode "kind" && pass "valid_cluster_mode accepts 'kind'" || fail "valid_cluster_mode accepts 'kind'"
_saas_vault_valid_cluster_mode "existing" && pass "valid_cluster_mode accepts 'existing'" || fail "valid_cluster_mode accepts 'existing'"
_saas_vault_valid_cluster_mode "cloud" && fail "valid_cluster_mode rejects 'cloud'" || pass "valid_cluster_mode rejects 'cloud'"

_saas_vault_valid_mode "dev" && pass "valid_mode accepts 'dev'" || fail "valid_mode accepts 'dev'"
_saas_vault_valid_mode "prod" && pass "valid_mode accepts 'prod'" || fail "valid_mode accepts 'prod'"
_saas_vault_valid_mode "staging" && fail "valid_mode rejects 'staging'" || pass "valid_mode rejects 'staging'"

_saas_vault_valid_tls_mode "self-signed" && pass "valid_tls_mode accepts 'self-signed'" || fail "valid_tls_mode accepts 'self-signed'"
_saas_vault_valid_tls_mode "letsencrypt" && pass "valid_tls_mode accepts 'letsencrypt'" || fail "valid_tls_mode accepts 'letsencrypt'"
_saas_vault_valid_tls_mode "none" && fail "valid_tls_mode rejects 'none'" || pass "valid_tls_mode rejects 'none'"

_saas_vault_valid_dns_provider "cloudflare" && pass "valid_dns_provider accepts 'cloudflare'" || fail "valid_dns_provider accepts 'cloudflare'"
_saas_vault_valid_dns_provider "duckdns" && fail "valid_dns_provider rejects 'duckdns' (deliberately narrower than gitlab)" || pass "valid_dns_provider rejects 'duckdns' (deliberately narrower than gitlab)"

_saas_vault_valid_key_shares "5" && pass "valid_key_shares accepts '5'" || fail "valid_key_shares accepts '5'"
_saas_vault_valid_key_shares "0" && fail "valid_key_shares rejects '0'" || pass "valid_key_shares rejects '0'"
_saas_vault_valid_key_shares "abc" && fail "valid_key_shares rejects non-numeric" || pass "valid_key_shares rejects non-numeric"

_saas_vault_valid_key_threshold "3" "5" && pass "valid_key_threshold accepts 3<=5" || fail "valid_key_threshold accepts 3<=5"
_saas_vault_valid_key_threshold "5" "5" && pass "valid_key_threshold accepts threshold==shares" || fail "valid_key_threshold accepts threshold==shares"
_saas_vault_valid_key_threshold "6" "5" && fail "valid_key_threshold rejects threshold>shares" || pass "valid_key_threshold rejects threshold>shares"
_saas_vault_valid_key_threshold "0" "5" && fail "valid_key_threshold rejects 0" || pass "valid_key_threshold rejects 0"

# ------------------------------------------------------------------
# _saas_vault_fullname: mirrors the chart's own '<chart>.fullname' Helm helper
# ------------------------------------------------------------------
[ "$(_saas_vault_fullname "openbao")" = "openbao" ] && pass "fullname: release 'openbao' -> 'openbao' (no duplication)" || fail "fullname: release 'openbao' -> 'openbao'"
[ "$(_saas_vault_fullname "vault")" = "vault-openbao" ] && pass "fullname: release 'vault' -> 'vault-openbao'" || fail "fullname: release 'vault' -> 'vault-openbao'"
[ "$(_saas_vault_fullname "my-openbao-demo")" = "my-openbao-demo" ] && pass "fullname: release containing 'openbao' -> used as-is" || fail "fullname: release containing 'openbao' -> used as-is"

# ------------------------------------------------------------------
# state.sh / secrets.sh roundtrip
# ------------------------------------------------------------------
_saas_vault_state_save "unittest" "RELEASE=unittest" "NAMESPACE=unittest" "MODE=dev" "KEY_SHARES=5" "KEY_THRESHOLD=3"
_saas_vault_state_load "unittest"
[ "$SAAS_VAULT_STATE_RELEASE" = "unittest" ] && [ "$SAAS_VAULT_STATE_KEY_THRESHOLD" = "3" ] \
    && pass "state: save/load roundtrip" || fail "state: save/load roundtrip"
_saas_vault_state_exists "unittest" && pass "state_exists true after save" || fail "state_exists true after save"
_saas_vault_state_delete "unittest"
_saas_vault_state_exists "unittest" && fail "state_delete removes the state" || pass "state_delete removes the state"

[ "$(_saas_vault_suggest_release)" = "vault" ] && pass "suggest_release with no saved state -> 'vault'" || fail "suggest_release with no saved state -> 'vault'"
_saas_vault_state_save "only" "RELEASE=only"
[ "$(_saas_vault_suggest_release)" = "only" ] && pass "suggest_release with a single saved state -> that release" || fail "suggest_release with a single saved state -> that release"
_saas_vault_state_delete "only"

_saas_vault_secrets_save "unittest" "s.roottoken123" "keyA,keyB,keyC,keyD,keyE"
_saas_vault_secrets_load "unittest"
[ "$SAAS_VAULT_KEYS_ROOT_TOKEN" = "s.roottoken123" ] && pass "secrets: root token roundtrip" || fail "secrets: root token roundtrip"
[ "$(_saas_vault_secrets_share_at 1 "$SAAS_VAULT_KEYS_SHARES_CSV")" = "keyA" ] && pass "secrets: share_at 1 -> first share" || fail "secrets: share_at 1 -> first share"
[ "$(_saas_vault_secrets_share_at 3 "$SAAS_VAULT_KEYS_SHARES_CSV")" = "keyC" ] && pass "secrets: share_at 3 -> third share" || fail "secrets: share_at 3 -> third share"
[ "$(_saas_vault_secrets_share_count "$SAAS_VAULT_KEYS_SHARES_CSV")" = "5" ] && pass "secrets: share_count" || fail "secrets: share_count"

perm="$(stat -c %a "$(_saas_vault_secrets_path "unittest")")"
[ "$perm" = "600" ] && pass "secrets: keys file is chmod 600" || fail "secrets: keys file is chmod 600 (got '$perm')"

_saas_vault_secrets_exists "unittest" && pass "secrets_exists true after save" || fail "secrets_exists true after save"
_saas_vault_secrets_delete "unittest"
_saas_vault_secrets_exists "unittest" && fail "secrets_delete removes the keys file" || pass "secrets_delete removes the keys file"

# ------------------------------------------------------------------
# _saas_vault_unseal_secret_apply: builds exactly THRESHOLD key1..keyN literals from the saved
# CSV, never more (even if more shares were saved), and never the root token.
# ------------------------------------------------------------------
_saas_vault_secrets_save "sealtest" "s.roottoken-should-never-appear" "k1,k2,k3,k4,k5"
# The 'create secret ... | kubectl apply' pipe runs its LEFT side in a subshell (same gotcha
# documented in tests/gitlab/unit/test-argparse-values.sh's CoreDNS test): a plain variable
# assignment made from inside the mocked kubectl there would be lost the instant that subshell
# exits, so capture it to a FILE instead, which survives.
_TEST_SECRET_ARGS_FILE="$(mktemp)"
kubectl() {
    case "$*" in
        "-n testns create secret generic sealtest-vault-unseal-keys --from-literal=key1=k1 --from-literal=key2=k2 --from-literal=key3=k3 --dry-run=client -o yaml")
            echo "$*" > "$_TEST_SECRET_ARGS_FILE" ;;
        "apply -f -") cat >/dev/null ;;
        "-n testns apply -f -") cat >/dev/null ;;
    esac
}
_saas_vault_unseal_secret_apply "sealtest" "testns" "3" >/dev/null 2>&1
_TEST_SECRET_ARGS="$(cat "$_TEST_SECRET_ARGS_FILE")"
[ -n "$_TEST_SECRET_ARGS" ] && pass "unseal_secret_apply: builds exactly 3 key literals for threshold=3" || fail "unseal_secret_apply: builds exactly 3 key literals for threshold=3"
echo "$_TEST_SECRET_ARGS" | grep -qF "key4" && fail "unseal_secret_apply: must not include a 4th share beyond the threshold" || pass "unseal_secret_apply: does not include shares beyond the threshold"
echo "$_TEST_SECRET_ARGS" | grep -qF "roottoken" && fail "unseal_secret_apply: must NEVER include the root token" || pass "unseal_secret_apply: never includes the root token"
unset -f kubectl
rm -f "$_TEST_SECRET_ARGS_FILE"
_saas_vault_secrets_delete "sealtest"

# ------------------------------------------------------------------
# 'saas vault integrate gitlab': order-independence is the safety-critical property here.
# Mock kubectl to control target-cluster reachability/reviewer-secret state, and count every
# Vault-mutating call (kv_engine_ensure/k8s_auth_ensure/etc go through _saas_vault_bao_exec,
# which execs into the pod) to prove NOTHING on the Vault side happens until both preflight
# conditions are met.
# ------------------------------------------------------------------
_saas_vault_state_save "obtest" "RELEASE=obtest" "NAMESPACE=obns" "MODE=dev" "DOMAIN=obtest.vault.local" "KEY_SHARES=5" "KEY_THRESHOLD=3"
_saas_vault_secrets_save "obtest" "s.roottoken" "k1,k2,k3,k4,k5"

_TEST_MUTATION_CALLS=0
_saas_vault_bao_exec() { _TEST_MUTATION_CALLS=$((_TEST_MUTATION_CALLS + 1)); echo '{}'; }
_saas_vault_bao_exec_stdin() { _TEST_MUTATION_CALLS=$((_TEST_MUTATION_CALLS + 1)); cat >/dev/null; }

# Case 1: Vault's own live status can't be verified (e.g. a stale/mocked pod) -> abort before
# even resolving the target context.
kubectl() { return 1; }
_TEST_MUTATION_CALLS=0
_saas_vault_integrate_gitlab --vault-release obtest --gitlab-context nonexistent-ctx >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] && pass "integrate gitlab: Vault unreachable -> fails, zero Vault mutation" || fail "integrate gitlab: Vault unreachable -> fails, zero Vault mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 2: Vault itself IS reachable/unsealed, but the target GitLab context is NOT reachable.
kubectl() {
    case "$*" in
        "-n obns exec obtest-openbao-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao status -format=json") echo '{"sealed":false,"initialized":true}' ;;
        "--context unreachable-ctx --request-timeout=10s get --raw /healthz") return 1 ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_saas_vault_integrate_gitlab --vault-release obtest --gitlab-context unreachable-ctx >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] \
    && pass "integrate gitlab: target unreachable -> fails, zero Vault mutation (order-independence)" \
    || fail "integrate gitlab: target unreachable -> fails, zero Vault mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 3: target reachable, but the reviewer ServiceAccount/token doesn't exist there yet.
kubectl() {
    case "$*" in
        "-n obns exec obtest-openbao-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao status -format=json") echo '{"sealed":false,"initialized":true}' ;;
        "--context reachable-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "--context reachable-ctx -n vault-integration get secret obtest-vault-reviewer-token") return 1 ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_TEST_OUT_DIR="$(mktemp -d)"
_saas_vault_integrate_gitlab --vault-release obtest --gitlab-context reachable-ctx --output-dir "$_TEST_OUT_DIR" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] && [ -f "$_TEST_OUT_DIR/gitlab-reviewer-serviceaccount.yaml" ] \
    && pass "integrate gitlab: reviewer secret missing -> renders manifest, fails, zero Vault mutation" \
    || fail "integrate gitlab: reviewer secret missing -> renders manifest, fails, zero Vault mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 4: fully ready (target reachable, reviewer secret present) -> Vault-side mutation DOES happen.
kubectl() {
    case "$*" in
        "-n obns exec obtest-openbao-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao status -format=json") echo '{"sealed":false,"initialized":true}' ;;
        "--context ready-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "--context ready-ctx -n vault-integration get secret obtest-vault-reviewer-token") return 0 ;;
        "--context ready-ctx -n vault-integration get secret obtest-vault-reviewer-token -o jsonpath={.data.token}") echo -n "dG9rZW4xMjM=" ;;
        --context\ ready-ctx\ -n\ vault-integration\ get\ secret\ obtest-vault-reviewer-token\ -o\ jsonpath=*ca*crt*) echo -n "Y2FjZXJ0" ;;
        "--context ready-ctx config view --minify --raw -o jsonpath={.clusters[0].cluster.server}") echo -n "https://ready-ctx-api:6443" ;;
        -n\ obns\ get\ secret\ obtest-vault-tls\ -o\ jsonpath=*tls*crt*) echo -n "dGxzY2VydA==" ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-psql -o jsonpath={.data.username}") return 1 ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-psql -o jsonpath={.data.password}") return 1 ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-minio -o jsonpath={.data.rootUser}") return 1 ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-minio -o jsonpath={.data.rootPassword}") return 1 ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-objectstore -o jsonpath={.data.connection}") return 1 ;;
        "--context ready-ctx -n gitlab get secret gitlab-datastore-s3cfg -o jsonpath={.data.config}") return 1 ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_TEST_OUT_DIR2="$(mktemp -d)"
_saas_vault_integrate_gitlab --vault-release obtest --gitlab-context ready-ctx --gitlab-namespace gitlab --output-dir "$_TEST_OUT_DIR2" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$_TEST_MUTATION_CALLS" -gt 0 ] && [ -f "$_TEST_OUT_DIR2/gitlab-secretstore.yaml" ] && [ -f "$_TEST_OUT_DIR2/gitlab-externalsecret.yaml" ] \
    && pass "integrate gitlab: fully ready -> Vault mutated and manifests rendered" \
    || fail "integrate gitlab: fully ready -> Vault mutated and manifests rendered (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl
unset -f _saas_vault_bao_exec _saas_vault_bao_exec_stdin
_saas_vault_state_delete "obtest"
_saas_vault_secrets_delete "obtest"

# ------------------------------------------------------------------
# 'saas gitlab integrate vault': the gitlab-side counterpart. Missing manifest dir -> clear
# error, no kubectl apply attempted at all.
# ------------------------------------------------------------------
_saas_gitlab_state_save "glbtest" "RELEASE=glbtest" "NAMESPACE=glbns"
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        apply*) _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_gitlab_integrate_vault --release glbtest --from-dir "/nonexistent/$$" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! $_TEST_APPLY_CALLED && pass "gitlab integrate vault: missing manifest dir -> clear error, no apply attempted" || fail "gitlab integrate vault: missing manifest dir -> clear error, no apply attempted"

# Reviewer manifest present, not yet applied -> gets applied exactly once.
_TEST_APPLY_CALLED=false
_TEST_DIR="$(mktemp -d)"
echo "apiVersion: v1" > "$_TEST_DIR/gitlab-reviewer-serviceaccount.yaml"
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount obtest-vault-reviewer") return 1 ;;
        "apply -f $_TEST_DIR/gitlab-reviewer-serviceaccount.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_gitlab_integrate_vault --release glbtest --vault-release obtest --from-dir "$_TEST_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "gitlab integrate vault: applies the reviewer manifest when not yet present" || fail "gitlab integrate vault: applies the reviewer manifest when not yet present"

# SecretStore/ExternalSecret present but ESO's CRD is missing -> refuses to apply.
_TEST_APPLY_CALLED=false
touch "$_TEST_DIR/gitlab-secretstore.yaml" "$_TEST_DIR/gitlab-externalsecret.yaml"
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount obtest-vault-reviewer") return 0 ;;
        "get crd externalsecrets.external-secrets.io") return 1 ;;
        apply*) _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_gitlab_integrate_vault --release glbtest --vault-release obtest --from-dir "$_TEST_DIR" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! $_TEST_APPLY_CALLED && pass "gitlab integrate vault: ESO CRD missing -> refuses to apply, clear error" || fail "gitlab integrate vault: ESO CRD missing -> refuses to apply, clear error"

# Fully ready -> applies the SecretStore/ExternalSecret.
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount obtest-vault-reviewer") return 0 ;;
        "get crd externalsecrets.external-secrets.io") return 0 ;;
        "-n glbns apply -f $_TEST_DIR/gitlab-secretstore.yaml -f $_TEST_DIR/gitlab-externalsecret.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_gitlab_integrate_vault --release glbtest --vault-release obtest --from-dir "$_TEST_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "gitlab integrate vault: fully ready -> applies SecretStore/ExternalSecret" || fail "gitlab integrate vault: fully ready -> applies SecretStore/ExternalSecret"
unset -f kubectl
_saas_gitlab_state_delete "glbtest"
rm -rf "$_TEST_DIR" "$_TEST_OUT_DIR" "$_TEST_OUT_DIR2"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
failed=0
for r in "${RESULTS[@]}"; do
    case "$r" in FAIL:*) failed=$((failed + 1)) ;; esac
done
echo ""
echo "Total: ${#RESULTS[@]}   Failed: $failed"
[ "$failed" -eq 0 ]
