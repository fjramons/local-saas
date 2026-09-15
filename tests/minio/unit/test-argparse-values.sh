#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas minio: validators, state roundtrip, doctor
# checks, bucket-name validation, and the order-independence guarantee of 'saas minio integrate
# gitlab' (its own MinIO cluster must never be mutated until the target GitLab cluster is
# confirmed reachable). Same mocking pattern as tests/gitlab/unit/ and tests/vault/unit/ (shadow
# kubectl/kind_cluster by defining same-named bash functions). Does not replace the real E2E
# suite (tests/minio/e2e/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Normally set by services/minio/minio.sh (not sourced here, only the individual lib files are,
# same as the gitlab/vault unit suites do for their own _SAAS_*_DIR); the integration functions
# need it to locate services/minio/values/*.yaml.tpl.
_SAAS_MINIO_DIR="$REPO_ROOT/services/minio"
declare -a RESULTS=()

pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

# kind_cluster isn't needed for these tests (no real cluster is touched); forcing the legacy
# backend (USE_KIND_CLUSTER_FUNCTION=true) and providing an empty 'kind_cluster' is simpler to
# mock than the default 'saas cluster' backend, which would try to create a real cluster.
export USE_KIND_CLUSTER_FUNCTION=true
kind_cluster() { :; }

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/services/minio/lib/state.sh"
source "$REPO_ROOT/services/minio/lib/cluster.sh"
source "$REPO_ROOT/services/minio/lib/backend.sh"
source "$REPO_ROOT/services/minio/lib/tls.sh"
source "$REPO_ROOT/services/minio/lib/install.sh"
source "$REPO_ROOT/services/minio/lib/credentials.sh"
source "$REPO_ROOT/services/minio/lib/doctor.sh"
source "$REPO_ROOT/services/minio/lib/bucket.sh"
source "$REPO_ROOT/services/minio/lib/integration_common.sh"
source "$REPO_ROOT/services/minio/lib/vault_integration.sh"
source "$REPO_ROOT/services/minio/lib/gitlab_integration.sh"

export SAAS_MINIO_STATE_DIR
SAAS_MINIO_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$SAAS_MINIO_STATE_DIR"' EXIT

# ------------------------------------------------------------------
# Pure validators
# ------------------------------------------------------------------
_saas_minio_valid_cluster_mode "kind" && pass "valid_cluster_mode accepts 'kind'" || fail "valid_cluster_mode accepts 'kind'"
_saas_minio_valid_cluster_mode "existing" && pass "valid_cluster_mode accepts 'existing'" || fail "valid_cluster_mode accepts 'existing'"
_saas_minio_valid_cluster_mode "cloud" && fail "valid_cluster_mode rejects 'cloud'" || pass "valid_cluster_mode rejects 'cloud'"

_saas_minio_valid_mode "dev" && pass "valid_mode accepts 'dev'" || fail "valid_mode accepts 'dev'"
_saas_minio_valid_mode "prod" && pass "valid_mode accepts 'prod'" || fail "valid_mode accepts 'prod'"
_saas_minio_valid_mode "staging" && fail "valid_mode rejects 'staging'" || pass "valid_mode rejects 'staging'"

_saas_minio_valid_tls_mode "self-signed" && pass "valid_tls_mode accepts 'self-signed'" || fail "valid_tls_mode accepts 'self-signed'"
_saas_minio_valid_tls_mode "letsencrypt" && pass "valid_tls_mode accepts 'letsencrypt'" || fail "valid_tls_mode accepts 'letsencrypt'"
_saas_minio_valid_tls_mode "none" && fail "valid_tls_mode rejects 'none'" || pass "valid_tls_mode rejects 'none'"

_saas_minio_valid_dns_provider "cloudflare" && pass "valid_dns_provider accepts 'cloudflare'" || fail "valid_dns_provider accepts 'cloudflare'"
_saas_minio_valid_dns_provider "duckdns" && fail "valid_dns_provider rejects 'duckdns' (deliberately narrower, same as vault)" || pass "valid_dns_provider rejects 'duckdns' (deliberately narrower, same as vault)"

_saas_minio_valid_bucket_name "my-bucket" && pass "valid_bucket_name accepts 'my-bucket'" || fail "valid_bucket_name accepts 'my-bucket'"
_saas_minio_valid_bucket_name "abc" && pass "valid_bucket_name accepts a 3-char name" || fail "valid_bucket_name accepts a 3-char name"
_saas_minio_valid_bucket_name "ab" && fail "valid_bucket_name rejects a 2-char name (too short)" || pass "valid_bucket_name rejects a 2-char name (too short)"
_saas_minio_valid_bucket_name "My-Bucket" && fail "valid_bucket_name rejects uppercase" || pass "valid_bucket_name rejects uppercase"
_saas_minio_valid_bucket_name "-leading-hyphen" && fail "valid_bucket_name rejects a leading hyphen" || pass "valid_bucket_name rejects a leading hyphen"
_saas_minio_valid_bucket_name "under_score" && fail "valid_bucket_name rejects underscores" || pass "valid_bucket_name rejects underscores"

# ------------------------------------------------------------------
# state.sh roundtrip
# ------------------------------------------------------------------
_saas_minio_state_save "unittest" "RELEASE=unittest" "NAMESPACE=unittest" "MODE=dev" "DOMAIN=unittest.minio.local" "BUCKETS=a,b"
_saas_minio_state_load "unittest"
[ "$SAAS_MINIO_STATE_RELEASE" = "unittest" ] && [ "$SAAS_MINIO_STATE_BUCKETS" = "a,b" ] \
    && pass "state: save/load roundtrip" || fail "state: save/load roundtrip"
_saas_minio_state_exists "unittest" && pass "state_exists true after save" || fail "state_exists true after save"
_saas_minio_state_delete "unittest"
_saas_minio_state_exists "unittest" && fail "state_delete removes the state" || pass "state_delete removes the state"

[ "$(_saas_minio_suggest_release)" = "minio" ] && pass "suggest_release with no saved state -> 'minio'" || fail "suggest_release with no saved state -> 'minio'"
_saas_minio_state_save "only" "RELEASE=only"
[ "$(_saas_minio_suggest_release)" = "only" ] && pass "suggest_release with a single saved state -> that release" || fail "suggest_release with a single saved state -> that release"
_saas_minio_state_delete "only"

# ------------------------------------------------------------------
# doctor: root credential drift, same source-of-truth-is-the-pod approach as gitlab's check
# ------------------------------------------------------------------
_TEST_REAL_PW="realpw123"
kubectl() {
    case "$*" in
        "-n doctorns get pods -l app=demo -o name") echo "pod/demo-xyz" ;;
        "-n doctorns exec demo-xyz -- printenv MINIO_ROOT_PASSWORD") echo "$_TEST_REAL_PW" ;;
        "-n doctorns get secret demo-credentials -o jsonpath={.data.rootPassword}") printf '%s' "$_TEST_REAL_PW" | base64 ;;
        *) return 1 ;;
    esac
}
out="$(_saas_minio_doctor_check_credentials doctorns demo)"
first_line="$(echo "$out" | sed -n 1p)"
line_count="$(echo "$out" | grep -c .)"
[ "$first_line" = "$_TEST_REAL_PW" ] && pass "doctor check_credentials: first line is the pod's real password" || fail "doctor check_credentials: first line is the pod's real password (got '$first_line')"
[ "$line_count" -eq 1 ] && pass "doctor check_credentials: no drift when the Secret matches" || fail "doctor check_credentials: no drift when the Secret matches"
unset -f kubectl

kubectl() {
    case "$*" in
        "-n doctorns get pods -l app=demo -o name") echo "pod/demo-xyz" ;;
        "-n doctorns exec demo-xyz -- printenv MINIO_ROOT_PASSWORD") echo "$_TEST_REAL_PW" ;;
        "-n doctorns get secret demo-credentials -o jsonpath={.data.rootPassword}") printf '%s' "stale-password" | base64 ;;
        *) return 1 ;;
    esac
}
out="$(_saas_minio_doctor_check_credentials doctorns demo)"
line_count="$(echo "$out" | grep -c .)"
[ "$line_count" -eq 2 ] && pass "doctor check_credentials: flags drift when the Secret doesn't match" || fail "doctor check_credentials: flags drift when the Secret doesn't match"
unset -f kubectl

kubectl() { return 1; }
_saas_minio_doctor_check_credentials doctorns demo >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "doctor check_credentials: nonzero exit when no pod is reachable" || fail "doctor check_credentials: nonzero exit when no pod is reachable"
unset -f kubectl

# ------------------------------------------------------------------
# 'saas minio integrate gitlab': order-independence is the safety-critical property here (same
# as vault's own two integrations): nothing on THIS MinIO cluster (bucket creation) may happen
# until the target GitLab cluster is confirmed reachable. Stub _saas_minio_init_buckets itself as
# the mutation counter, since it's the one call that actually touches MinIO's own cluster here.
# ------------------------------------------------------------------
_saas_minio_state_save "miniotest" "RELEASE=miniotest" "NAMESPACE=minions" "DOMAIN=miniotest.minio.local" "ROOT_USER=u" "ROOT_PASSWORD=p"
_TEST_MUTATION_CALLS=0
_saas_minio_init_buckets() { _TEST_MUTATION_CALLS=$((_TEST_MUTATION_CALLS + 1)); return 0; }

# Case 1: this MinIO release itself isn't reachable/up.
kubectl() { return 1; }
_TEST_MUTATION_CALLS=0
_saas_minio_integrate_gitlab --minio-release miniotest --gitlab-context nonexistent-ctx --gitlab-namespace gitlab >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] && pass "integrate gitlab: MinIO itself unreachable -> fails, zero MinIO mutation" || fail "integrate gitlab: MinIO itself unreachable -> fails, zero MinIO mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 2: MinIO is up, but the target GitLab context is NOT reachable.
kubectl() {
    case "$*" in
        "-n minions get pods -l app=miniotest -o jsonpath={.items[*].status.containerStatuses[*].ready}") echo "true" ;;
        "--context unreachable-ctx --request-timeout=10s get --raw /healthz") return 1 ;;
        "config current-context") echo "some-other-ctx" ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_saas_minio_integrate_gitlab --minio-release miniotest --gitlab-context unreachable-ctx --gitlab-namespace gitlab >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] \
    && pass "integrate gitlab: target unreachable -> fails, zero MinIO mutation (order-independence)" \
    || fail "integrate gitlab: target unreachable -> fails, zero MinIO mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 3: fully ready (MinIO up, target reachable, same context as MinIO's own) -> mutation DOES
# happen (bucket creation), and the manifest is rendered pointing at the INTERNAL endpoint.
kubectl() {
    case "$*" in
        "-n minions get pods -l app=miniotest -o jsonpath={.items[*].status.containerStatuses[*].ready}") echo "true" ;;
        "--context same-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "config current-context") echo "same-ctx" ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_TEST_GL_OUT_DIR="$(mktemp -d)"
_saas_minio_integrate_gitlab --minio-release miniotest --gitlab-context same-ctx --gitlab-namespace gitlab --output-dir "$_TEST_GL_OUT_DIR" >/dev/null 2>&1
rc=$?
manifest="$_TEST_GL_OUT_DIR/gitlab-datastore-secrets.yaml"
[ "$rc" -eq 0 ] && [ "$_TEST_MUTATION_CALLS" -gt 0 ] && [ -f "$manifest" ] \
    && pass "integrate gitlab: fully ready (same cluster) -> buckets created, manifest rendered" \
    || fail "integrate gitlab: fully ready (same cluster) -> buckets created, manifest rendered (rc=$rc calls=$_TEST_MUTATION_CALLS)"
grep -qF "miniotest.minions.svc.cluster.local:9000" "$manifest" 2>/dev/null \
    && pass "integrate gitlab: same-cluster endpoint is the internal Service DNS name, plain HTTP" \
    || fail "integrate gitlab: same-cluster endpoint is the internal Service DNS name, plain HTTP"
unset -f kubectl

# Case 4: MinIO and GitLab on DIFFERENT contexts -> renders the external HTTPS endpoint instead.
kubectl() {
    case "$*" in
        "-n minions get pods -l app=miniotest -o jsonpath={.items[*].status.containerStatuses[*].ready}") echo "true" ;;
        "--context other-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "config current-context") echo "same-ctx" ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_TEST_GL_OUT_DIR2="$(mktemp -d)"
_saas_minio_integrate_gitlab --minio-release miniotest --gitlab-context other-ctx --gitlab-namespace gitlab --output-dir "$_TEST_GL_OUT_DIR2" >/dev/null 2>&1
manifest2="$_TEST_GL_OUT_DIR2/gitlab-datastore-secrets.yaml"
grep -qF "https://s3.miniotest.minio.local" "$manifest2" 2>/dev/null \
    && pass "integrate gitlab: cross-cluster endpoint is MinIO's external HTTPS ingress" \
    || fail "integrate gitlab: cross-cluster endpoint is MinIO's external HTTPS ingress"
unset -f kubectl
unset -f _saas_minio_init_buckets
_saas_minio_state_delete "miniotest"
rm -rf "$_TEST_GL_OUT_DIR" "$_TEST_GL_OUT_DIR2"

# ------------------------------------------------------------------
# 'saas minio integrate vault': the apply-only counterpart. Same shape/tests as gitlab's own
# 'integrate vault' (services/gitlab/lib/vault_integration.sh).
# ------------------------------------------------------------------
_saas_minio_state_save "mvtest" "RELEASE=mvtest" "NAMESPACE=mvns"
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        apply*) _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_minio_integrate_vault --release mvtest --from-dir "/nonexistent/$$" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! $_TEST_APPLY_CALLED && pass "minio integrate vault: missing manifest dir -> clear error, no apply attempted" || fail "minio integrate vault: missing manifest dir -> clear error, no apply attempted"

_TEST_MV_DIR="$(mktemp -d)"
echo "apiVersion: v1" > "$_TEST_MV_DIR/minio-reviewer-serviceaccount.yaml"
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount vtest-vault-reviewer") return 1 ;;
        "apply -f $_TEST_MV_DIR/minio-reviewer-serviceaccount.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_TEST_APPLY_CALLED=false
_saas_minio_integrate_vault --release mvtest --vault-release vtest --from-dir "$_TEST_MV_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "minio integrate vault: applies the reviewer manifest when not yet present" || fail "minio integrate vault: applies the reviewer manifest when not yet present"

touch "$_TEST_MV_DIR/minio-secretstore.yaml" "$_TEST_MV_DIR/minio-externalsecret.yaml"
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount vtest-vault-reviewer") return 0 ;;
        "get crd externalsecrets.external-secrets.io") return 0 ;;
        "-n mvns apply -f $_TEST_MV_DIR/minio-secretstore.yaml -f $_TEST_MV_DIR/minio-externalsecret.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_minio_integrate_vault --release mvtest --vault-release vtest --from-dir "$_TEST_MV_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "minio integrate vault: fully ready -> applies SecretStore/ExternalSecret" || fail "minio integrate vault: fully ready -> applies SecretStore/ExternalSecret"
unset -f kubectl
_saas_minio_state_delete "mvtest"
rm -rf "$_TEST_MV_DIR"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
total="${#RESULTS[@]}"
failed=0
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL:* ]] && failed=$((failed + 1)); done
echo "Total: $total   Failed: $failed"
[ "$failed" -eq 0 ]
