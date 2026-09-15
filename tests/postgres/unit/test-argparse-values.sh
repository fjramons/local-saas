#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas postgres: validators, state roundtrip, doctor
# checks, and the order-independence guarantee of both 'saas postgres integrate gitlab' and
# 'saas postgres integrate vault' (this postgres release's own cluster must never be mutated until
# the target cluster is confirmed reachable). Same mocking pattern as tests/minio/unit/ (shadow
# kubectl/kind_cluster by defining same-named bash functions). Does not replace the real E2E suite
# (tests/postgres/e2e/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Normally set by services/postgres/postgres.sh (not sourced here, only the individual lib files
# are, same as the other services' own unit suites do for their own _SAAS_*_DIR); the integration
# functions need it to locate services/postgres/values/*.yaml.tpl.
_SAAS_POSTGRES_DIR="$REPO_ROOT/services/postgres"
declare -a RESULTS=()

pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

# kind_cluster isn't needed for these tests (no real cluster is touched); forcing the legacy
# backend (USE_KIND_CLUSTER_FUNCTION=true) and providing an empty 'kind_cluster' is simpler to
# mock than the default 'saas cluster' backend, which would try to create a real cluster.
export USE_KIND_CLUSTER_FUNCTION=true
kind_cluster() { :; }

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/services/postgres/lib/state.sh"
source "$REPO_ROOT/services/postgres/lib/cluster.sh"
source "$REPO_ROOT/services/postgres/lib/expose.sh"
source "$REPO_ROOT/services/postgres/lib/tls.sh"
source "$REPO_ROOT/services/postgres/lib/backend.sh"
source "$REPO_ROOT/services/postgres/lib/install.sh"
source "$REPO_ROOT/services/postgres/lib/credentials.sh"
source "$REPO_ROOT/services/postgres/lib/doctor.sh"
source "$REPO_ROOT/services/postgres/lib/database.sh"
source "$REPO_ROOT/services/postgres/lib/integration_common.sh"
source "$REPO_ROOT/services/postgres/lib/vault_integration.sh"
source "$REPO_ROOT/services/postgres/lib/gitlab_integration.sh"

export SAAS_POSTGRES_STATE_DIR
SAAS_POSTGRES_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$SAAS_POSTGRES_STATE_DIR"' EXIT

# ------------------------------------------------------------------
# Pure validators
# ------------------------------------------------------------------
_saas_postgres_valid_cluster_mode "kind" && pass "valid_cluster_mode accepts 'kind'" || fail "valid_cluster_mode accepts 'kind'"
_saas_postgres_valid_cluster_mode "existing" && pass "valid_cluster_mode accepts 'existing'" || fail "valid_cluster_mode accepts 'existing'"
_saas_postgres_valid_cluster_mode "cloud" && fail "valid_cluster_mode rejects 'cloud'" || pass "valid_cluster_mode rejects 'cloud'"

_saas_postgres_valid_mode "dev" && pass "valid_mode accepts 'dev'" || fail "valid_mode accepts 'dev'"
_saas_postgres_valid_mode "prod" && pass "valid_mode accepts 'prod'" || fail "valid_mode accepts 'prod'"
_saas_postgres_valid_mode "staging" && fail "valid_mode rejects 'staging'" || pass "valid_mode rejects 'staging'"

_saas_postgres_valid_tls_mode "self-signed" && pass "valid_tls_mode accepts 'self-signed'" || fail "valid_tls_mode accepts 'self-signed'"
_saas_postgres_valid_tls_mode "letsencrypt" && pass "valid_tls_mode accepts 'letsencrypt'" || fail "valid_tls_mode accepts 'letsencrypt'"
_saas_postgres_valid_tls_mode "none" && fail "valid_tls_mode rejects 'none'" || pass "valid_tls_mode rejects 'none'"

_saas_postgres_valid_challenge "http01" && pass "valid_challenge accepts 'http01'" || fail "valid_challenge accepts 'http01'"
_saas_postgres_valid_challenge "dns01" && pass "valid_challenge accepts 'dns01'" || fail "valid_challenge accepts 'dns01'"
_saas_postgres_valid_challenge "tls-alpn" && fail "valid_challenge rejects 'tls-alpn'" || pass "valid_challenge rejects 'tls-alpn'"

_saas_postgres_valid_dns_provider "cloudflare" && pass "valid_dns_provider accepts 'cloudflare'" || fail "valid_dns_provider accepts 'cloudflare'"
_saas_postgres_valid_dns_provider "duckdns" && fail "valid_dns_provider rejects 'duckdns' (deliberately narrower, same as vault/minio)" || pass "valid_dns_provider rejects 'duckdns' (deliberately narrower, same as vault/minio)"

_saas_postgres_valid_workers "0" && pass "valid_workers accepts '0'" || fail "valid_workers accepts '0'"
_saas_postgres_valid_workers "3" && pass "valid_workers accepts '3'" || fail "valid_workers accepts '3'"
_saas_postgres_valid_workers "-1" && fail "valid_workers rejects '-1'" || pass "valid_workers rejects '-1'"

_saas_postgres_valid_username "admin" && pass "valid_username accepts 'admin'" || fail "valid_username accepts 'admin'"
_saas_postgres_valid_username "_underscore" && pass "valid_username accepts a leading underscore" || fail "valid_username accepts a leading underscore"
_saas_postgres_valid_username "9numeric" && fail "valid_username rejects a leading digit" || pass "valid_username rejects a leading digit"
_saas_postgres_valid_username "Has-Caps" && fail "valid_username rejects uppercase/hyphen" || pass "valid_username rejects uppercase/hyphen"

_saas_postgres_valid_database_name "myapp" && pass "valid_database_name accepts 'myapp'" || fail "valid_database_name accepts 'myapp'"
_saas_postgres_valid_database_name "gitlabhq_production" && pass "valid_database_name accepts 'gitlabhq_production'" || fail "valid_database_name accepts 'gitlabhq_production'"

_saas_postgres_valid_admin_username "admin" && pass "valid_admin_username accepts 'admin'" || fail "valid_admin_username accepts 'admin'"
_saas_postgres_valid_admin_username "postgres" && fail "valid_admin_username rejects the reserved name 'postgres' (CNPG superuser, see backend.sh)" || pass "valid_admin_username rejects the reserved name 'postgres' (CNPG superuser, see backend.sh)"

_saas_postgres_valid_hostport "5432" && pass "valid_hostport accepts '5432'" || fail "valid_hostport accepts '5432'"
_saas_postgres_valid_hostport "70000" && fail "valid_hostport rejects a port above 65535" || pass "valid_hostport rejects a port above 65535"

# ------------------------------------------------------------------
# state.sh roundtrip
# ------------------------------------------------------------------
_saas_postgres_state_save "unittest" "RELEASE=unittest" "NAMESPACE=unittest" "MODE=dev" "USERNAME=admin" "DATABASES=a,b"
_saas_postgres_state_load "unittest"
[ "$SAAS_POSTGRES_STATE_RELEASE" = "unittest" ] && [ "$SAAS_POSTGRES_STATE_DATABASES" = "a,b" ] \
    && pass "state: save/load roundtrip" || fail "state: save/load roundtrip"
_saas_postgres_state_exists "unittest" && pass "state_exists true after save" || fail "state_exists true after save"
_saas_postgres_state_delete "unittest"
_saas_postgres_state_exists "unittest" && fail "state_delete removes the state" || pass "state_delete removes the state"

[ "$(_saas_postgres_suggest_release)" = "postgres" ] && pass "suggest_release with no saved state -> 'postgres'" || fail "suggest_release with no saved state -> 'postgres'"
_saas_postgres_state_save "only" "RELEASE=only"
[ "$(_saas_postgres_suggest_release)" = "only" ] && pass "suggest_release with a single saved state -> that release" || fail "suggest_release with a single saved state -> that release"
_saas_postgres_state_delete "only"

# ------------------------------------------------------------------
# _saas_postgres_primary_pod: dev mode is a fixed name, prod mode reads the CNPG Cluster's
# status.currentPrimary (verified live against a real installed CNPG, see backend.sh).
# ------------------------------------------------------------------
[ "$(_saas_postgres_primary_pod ns demo dev)" = "demo-postgresql-0" ] \
    && pass "primary_pod: dev mode is always '<release>-postgresql-0'" || fail "primary_pod: dev mode is always '<release>-postgresql-0'"

kubectl() {
    case "$*" in
        "-n ns get cluster demo-postgresql -o jsonpath={.status.currentPrimary}") echo "demo-postgresql-2" ;;
        *) return 1 ;;
    esac
}
[ "$(_saas_postgres_primary_pod ns demo prod)" = "demo-postgresql-2" ] \
    && pass "primary_pod: prod mode reads status.currentPrimary" || fail "primary_pod: prod mode reads status.currentPrimary"
unset -f kubectl

# ------------------------------------------------------------------
# doctor: admin credential drift (--mode dev only), same source-of-truth-is-a-live-auth-check
# approach as gitlab's own PostgreSQL check. _saas_postgres_psql_run always connects over TCP to
# 127.0.0.1 with sslmode=require (see database.sh for why, verified live), never a bare local
# socket, so the mocked kubectl command below reflects that exact invocation shape.
# ------------------------------------------------------------------
kubectl() {
    case "$*" in
        "-n doctorns get pod demo-postgresql-0") return 0 ;;
        "-n doctorns exec demo-postgresql-0 -c postgres -- env PGPASSWORD=realpw123 psql host=127.0.0.1 user=admin dbname=postgres sslmode=require -tAc SELECT 1") return 0 ;;
        *) return 1 ;;
    esac
}
[ "$(_saas_postgres_doctor_check_credentials doctorns demo-postgresql-0 admin realpw123)" = "ok" ] \
    && pass "doctor check_credentials: 'ok' when the saved password authenticates" || fail "doctor check_credentials: 'ok' when the saved password authenticates"
unset -f kubectl

kubectl() {
    case "$*" in
        "-n doctorns get pod demo-postgresql-0") return 0 ;;
        *) return 1 ;;
    esac
}
[ "$(_saas_postgres_doctor_check_credentials doctorns demo-postgresql-0 admin wrongpw)" = "mismatch" ] \
    && pass "doctor check_credentials: 'mismatch' when the saved password doesn't authenticate" || fail "doctor check_credentials: 'mismatch' when the saved password doesn't authenticate"
unset -f kubectl

kubectl() { return 1; }
[ "$(_saas_postgres_doctor_check_credentials doctorns demo-postgresql-0 admin x)" = "unreachable" ] \
    && pass "doctor check_credentials: 'unreachable' when the pod doesn't exist" || fail "doctor check_credentials: 'unreachable' when the pod doesn't exist"
unset -f kubectl

# ------------------------------------------------------------------
# 'saas postgres integrate gitlab': order-independence is the safety-critical property here (same
# as MinIO's/Vault's own integrations): nothing on THIS postgres cluster (database/role creation)
# may happen until the target GitLab cluster is confirmed reachable. Stub
# _saas_postgres_database_create_internal itself as the mutation counter, since it's the one call
# that actually touches postgres's own cluster in this flow.
# ------------------------------------------------------------------
_saas_postgres_state_save "pgtest" "RELEASE=pgtest" "NAMESPACE=pgns" "MODE=dev" "USERNAME=admin" "ADMIN_PASSWORD=p" "EXPOSE=false"
_TEST_MUTATION_CALLS=0
_saas_postgres_database_create_internal() { _TEST_MUTATION_CALLS=$((_TEST_MUTATION_CALLS + 1)); return 0; }

# Case 1: this postgres release itself isn't reachable/up.
kubectl() { return 1; }
_TEST_MUTATION_CALLS=0
_saas_postgres_integrate_gitlab --postgres-release pgtest --gitlab-context nonexistent-ctx --gitlab-namespace gitlab >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] && pass "integrate gitlab: postgres itself unreachable -> fails, zero mutation" || fail "integrate gitlab: postgres itself unreachable -> fails, zero mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 2: postgres is up, but the target GitLab context is NOT reachable.
kubectl() {
    case "$*" in
        "-n pgns get pod pgtest-postgresql-0") return 0 ;;
        "-n pgns get pod pgtest-postgresql-0 -o jsonpath={.status.containerStatuses[*].ready}") echo "true" ;;
        "--context unreachable-ctx --request-timeout=10s get --raw /healthz") return 1 ;;
        "config current-context") echo "some-other-ctx" ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_saas_postgres_integrate_gitlab --postgres-release pgtest --gitlab-context unreachable-ctx --gitlab-namespace gitlab >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] \
    && pass "integrate gitlab: target unreachable -> fails, zero mutation (order-independence)" \
    || fail "integrate gitlab: target unreachable -> fails, zero mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl

# Case 3: fully ready (postgres up, target reachable, same context as postgres's own) -> mutation
# DOES happen (2 databases created), and the manifest/connection file point at the internal DNS name.
kubectl() {
    case "$*" in
        "-n pgns get pod pgtest-postgresql-0") return 0 ;;
        "-n pgns get pod pgtest-postgresql-0 -o jsonpath={.status.containerStatuses[*].ready}") echo "true" ;;
        "--context same-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "config current-context") echo "same-ctx" ;;
        "-n pgns get secret pgtest-gitlab-credentials -o jsonpath={.data.password}") return 1 ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_TEST_GL_OUT_DIR="$(mktemp -d)"
_saas_postgres_integrate_gitlab --postgres-release pgtest --gitlab-release gitlab --gitlab-context same-ctx --gitlab-namespace gitlab --output-dir "$_TEST_GL_OUT_DIR" >/dev/null 2>&1
rc=$?
manifest="$_TEST_GL_OUT_DIR/gitlab-datastore-psql-secret.yaml"
conn="$_TEST_GL_OUT_DIR/gitlab-datastore-psql-connection.env"
[ "$rc" -eq 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 2 ] && [ -f "$manifest" ] && [ -f "$conn" ] \
    && pass "integrate gitlab: fully ready (same cluster) -> 2 databases created, manifest+connection rendered" \
    || fail "integrate gitlab: fully ready (same cluster) -> 2 databases created, manifest+connection rendered (rc=$rc calls=$_TEST_MUTATION_CALLS)"
grep -qF "pgtest-postgresql.pgns.svc.cluster.local" "$conn" 2>/dev/null \
    && pass "integrate gitlab: same-cluster endpoint is the internal Service DNS name" \
    || fail "integrate gitlab: same-cluster endpoint is the internal Service DNS name"
grep -qF "name: gitlab-datastore-psql" "$manifest" 2>/dev/null \
    && pass "integrate gitlab: rendered Secret is named '<gitlab-release>-datastore-psql'" \
    || fail "integrate gitlab: rendered Secret is named '<gitlab-release>-datastore-psql'"
unset -f kubectl

# Case 4: postgres and GitLab on DIFFERENT contexts, and this release was NOT installed with
# --expose -> fails cleanly with an actionable message, zero mutation (a documented, deliberate
# gap, same class as MinIO's/Vault's own cross-cluster gaps).
kubectl() {
    case "$*" in
        "-n pgns get pod pgtest-postgresql-0") return 0 ;;
        "-n pgns get pod pgtest-postgresql-0 -o jsonpath={.status.containerStatuses[*].ready}") echo "true" ;;
        "--context other-ctx --request-timeout=10s get --raw /healthz") return 0 ;;
        "config current-context") echo "same-ctx" ;;
        *) return 1 ;;
    esac
}
_TEST_MUTATION_CALLS=0
_saas_postgres_integrate_gitlab --postgres-release pgtest --gitlab-context other-ctx --gitlab-namespace gitlab >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$_TEST_MUTATION_CALLS" -eq 0 ] \
    && pass "integrate gitlab: cross-cluster without --expose -> fails cleanly, zero mutation" \
    || fail "integrate gitlab: cross-cluster without --expose -> fails cleanly, zero mutation (rc=$rc calls=$_TEST_MUTATION_CALLS)"
unset -f kubectl
unset -f _saas_postgres_database_create_internal
_saas_postgres_state_delete "pgtest"
rm -rf "$_TEST_GL_OUT_DIR"

# ------------------------------------------------------------------
# 'saas postgres integrate vault': the apply-only counterpart. Same shape/tests as MinIO's own
# 'integrate vault' (services/minio/lib/vault_integration.sh).
# ------------------------------------------------------------------
_saas_postgres_state_save "pvtest" "RELEASE=pvtest" "NAMESPACE=pvns"
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        apply*) _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_postgres_integrate_vault --release pvtest --from-dir "/nonexistent/$$" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! $_TEST_APPLY_CALLED && pass "postgres integrate vault: missing manifest dir -> clear error, no apply attempted" || fail "postgres integrate vault: missing manifest dir -> clear error, no apply attempted"

_TEST_PV_DIR="$(mktemp -d)"
echo "apiVersion: v1" > "$_TEST_PV_DIR/postgres-reviewer-serviceaccount.yaml"
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount vtest-vault-reviewer") return 1 ;;
        "apply -f $_TEST_PV_DIR/postgres-reviewer-serviceaccount.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_TEST_APPLY_CALLED=false
_saas_postgres_integrate_vault --release pvtest --vault-release vtest --from-dir "$_TEST_PV_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "postgres integrate vault: applies the reviewer manifest when not yet present" || fail "postgres integrate vault: applies the reviewer manifest when not yet present"

touch "$_TEST_PV_DIR/postgres-secretstore.yaml" "$_TEST_PV_DIR/postgres-externalsecret.yaml"
_TEST_APPLY_CALLED=false
kubectl() {
    case "$*" in
        "-n vault-integration get serviceaccount vtest-vault-reviewer") return 0 ;;
        "get crd externalsecrets.external-secrets.io") return 0 ;;
        "-n pvns apply -f $_TEST_PV_DIR/postgres-secretstore.yaml -f $_TEST_PV_DIR/postgres-externalsecret.yaml") _TEST_APPLY_CALLED=true ;;
        *) return 1 ;;
    esac
}
_saas_postgres_integrate_vault --release pvtest --vault-release vtest --from-dir "$_TEST_PV_DIR" >/dev/null 2>&1
$_TEST_APPLY_CALLED && pass "postgres integrate vault: fully ready -> applies SecretStore/ExternalSecret" || fail "postgres integrate vault: fully ready -> applies SecretStore/ExternalSecret"
unset -f kubectl
_saas_postgres_state_delete "pvtest"
rm -rf "$_TEST_PV_DIR"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
total="${#RESULTS[@]}"
failed=0
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL:* ]] && failed=$((failed + 1)); done
echo "Total: $total   Failed: $failed"
[ "$failed" -eq 0 ]
