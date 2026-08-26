#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas gitlab: validators, StorageClass/version resolution, persistent state, ~/.ssh/config snippet generation. Mocks kubectl/helm/kind_cluster by shadowing functions, same pattern as tests/kind-cluster/test-suggest-target.sh in the sibling bash-aliases repo. Does not replace the real E2E suite (tests/gitlab/e2e/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
declare -a RESULTS=()

pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

# kind_cluster isn't needed for these tests (no real cluster is touched), but several files call _saas_gitlab_require_kind_cluster_fn, which only checks 'command -v kind_cluster'. We provide an empty one.
kind_cluster() { :; }

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/services/gitlab/lib/state.sh"
source "$REPO_ROOT/services/gitlab/lib/cluster.sh"
source "$REPO_ROOT/services/gitlab/lib/versions.sh"
source "$REPO_ROOT/services/gitlab/lib/operators.sh"
source "$REPO_ROOT/services/gitlab/lib/tls.sh"
source "$REPO_ROOT/services/gitlab/lib/ssh.sh"
source "$REPO_ROOT/services/gitlab/lib/credentials.sh"
source "$REPO_ROOT/services/gitlab/lib/install.sh"

export SAAS_GITLAB_STATE_DIR
SAAS_GITLAB_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$SAAS_GITLAB_STATE_DIR"' EXIT

# ------------------------------------------------------------------
# Pure validators
# ------------------------------------------------------------------
_saas_gitlab_valid_cluster_mode "kind" && pass "valid_cluster_mode accepts 'kind'" || fail "valid_cluster_mode accepts 'kind'"
_saas_gitlab_valid_cluster_mode "existing" && pass "valid_cluster_mode accepts 'existing'" || fail "valid_cluster_mode accepts 'existing'"
_saas_gitlab_valid_cluster_mode "cloud" && fail "valid_cluster_mode rejects 'cloud'" || pass "valid_cluster_mode rejects 'cloud'"

_saas_gitlab_valid_tls_mode "self-signed" && pass "valid_tls_mode accepts 'self-signed'" || fail "valid_tls_mode accepts 'self-signed'"
_saas_gitlab_valid_tls_mode "letsencrypt" && pass "valid_tls_mode accepts 'letsencrypt'" || fail "valid_tls_mode accepts 'letsencrypt'"
_saas_gitlab_valid_tls_mode "none" && fail "valid_tls_mode rejects 'none'" || pass "valid_tls_mode rejects 'none'"

_saas_gitlab_valid_dns_provider "cloudflare" && pass "valid_dns_provider accepts 'cloudflare'" || fail "valid_dns_provider accepts 'cloudflare'"
_saas_gitlab_valid_dns_provider "route53" && fail "valid_dns_provider rejects an unsupported provider" || pass "valid_dns_provider rejects an unsupported provider"

_saas_gitlab_valid_pages_url_mode "path" && pass "valid_pages_url_mode accepts 'path'" || fail "valid_pages_url_mode accepts 'path'"
_saas_gitlab_valid_pages_url_mode "subdomain" && pass "valid_pages_url_mode accepts 'subdomain'" || fail "valid_pages_url_mode accepts 'subdomain'"
_saas_gitlab_valid_pages_url_mode "wildcard" && fail "valid_pages_url_mode rejects an unknown mode" || pass "valid_pages_url_mode rejects an unknown mode"

# _saas_gitlab_valid_pages_subdomain_tls: 'path' never depends on TLS/challenge; 'subdomain' is fine
# with self-signed (no CA validation at all) or letsencrypt+dns01 (the only ACME wildcard challenge),
# and rejected otherwise.
_saas_gitlab_valid_pages_subdomain_tls "path" "self-signed" "" && pass "pages_subdomain_tls: path + self-signed always ok" || fail "pages_subdomain_tls: path + self-signed always ok"
_saas_gitlab_valid_pages_subdomain_tls "path" "letsencrypt" "http01" && pass "pages_subdomain_tls: path + letsencrypt/http01 always ok" || fail "pages_subdomain_tls: path + letsencrypt/http01 always ok"
_saas_gitlab_valid_pages_subdomain_tls "subdomain" "self-signed" "" && pass "pages_subdomain_tls: subdomain + self-signed ok (no CA involved)" || fail "pages_subdomain_tls: subdomain + self-signed ok (no CA involved)"
_saas_gitlab_valid_pages_subdomain_tls "subdomain" "letsencrypt" "dns01" && pass "pages_subdomain_tls: subdomain + letsencrypt/dns01 ok" || fail "pages_subdomain_tls: subdomain + letsencrypt/dns01 ok"
_saas_gitlab_valid_pages_subdomain_tls "subdomain" "letsencrypt" "http01" && fail "pages_subdomain_tls: subdomain + letsencrypt/http01 rejected" || pass "pages_subdomain_tls: subdomain + letsencrypt/http01 rejected"

# ------------------------------------------------------------------
# Persistent state: roundtrip, including values with spaces/quotes
# ------------------------------------------------------------------
_saas_gitlab_state_save "unittest" "RELEASE=unittest" "NAMESPACE=unittest" \
    "DOMAIN=unittest.gitlab.local" "PSQL_PASSWORD=p@ss w/ spaces \"and quotes\"" \
    "REGISTRY_ENABLED=true" "PAGES_ENABLED=false" "PAGES_URL_MODE=subdomain" "REDIS_PASSWORD=redispw123" "STATUS=up"

if _saas_gitlab_state_load "unittest"; then
    [ "$SAAS_GITLAB_STATE_RELEASE" = "unittest" ] && pass "state roundtrip: RELEASE" || fail "state roundtrip: RELEASE (got '$SAAS_GITLAB_STATE_RELEASE')"
    [ "$SAAS_GITLAB_STATE_DOMAIN" = "unittest.gitlab.local" ] && pass "state roundtrip: DOMAIN" || fail "state roundtrip: DOMAIN"
    [ "$SAAS_GITLAB_STATE_PSQL_PASSWORD" = 'p@ss w/ spaces "and quotes"' ] && pass "state roundtrip: value with spaces/quotes" || fail "state roundtrip: value with spaces/quotes (got '$SAAS_GITLAB_STATE_PSQL_PASSWORD')"
    [ "$SAAS_GITLAB_STATE_REGISTRY_ENABLED" = "true" ] && pass "state roundtrip: REGISTRY_ENABLED" || fail "state roundtrip: REGISTRY_ENABLED"
    [ "$SAAS_GITLAB_STATE_PAGES_ENABLED" = "false" ] && pass "state roundtrip: PAGES_ENABLED" || fail "state roundtrip: PAGES_ENABLED"
    [ "$SAAS_GITLAB_STATE_PAGES_URL_MODE" = "subdomain" ] && pass "state roundtrip: PAGES_URL_MODE" || fail "state roundtrip: PAGES_URL_MODE (got '$SAAS_GITLAB_STATE_PAGES_URL_MODE')"
    [ "$SAAS_GITLAB_STATE_REDIS_PASSWORD" = "redispw123" ] && pass "state roundtrip: REDIS_PASSWORD" || fail "state roundtrip: REDIS_PASSWORD"
else
    fail "state roundtrip: could not load the just-saved state"
fi

_saas_gitlab_state_exists "unittest" && pass "state_exists detects a saved state" || fail "state_exists detects a saved state"
_saas_gitlab_state_exists "does-not-exist" && fail "state_exists doesn't detect a nonexistent state" || pass "state_exists doesn't detect a nonexistent state"

_saas_gitlab_state_save_key "unittest" "STATUS" "down" >/dev/null
# Unset before reloading: 'source'-ing a state file that OMITS a key leaves any previously-set
# shell variable of the same name untouched, which would make a broken 'fields' list in state.sh
# (one missing the new keys) look like it "preserved" them when it actually just silently dropped
# them from the file: this happened for real while adding REGISTRY_ENABLED/PAGES_ENABLED/
# REDIS_PASSWORD, and the reload-only assertion below didn't catch it. Cross-check the raw file too.
unset SAAS_GITLAB_STATE_STATUS SAAS_GITLAB_STATE_DOMAIN SAAS_GITLAB_STATE_REGISTRY_ENABLED SAAS_GITLAB_STATE_PAGES_ENABLED SAAS_GITLAB_STATE_PAGES_URL_MODE SAAS_GITLAB_STATE_REDIS_PASSWORD
_saas_gitlab_state_load "unittest"
[ "$SAAS_GITLAB_STATE_STATUS" = "down" ] && pass "state_save_key updates a single key" || fail "state_save_key updates a single key"
[ "$SAAS_GITLAB_STATE_DOMAIN" = "unittest.gitlab.local" ] && pass "state_save_key preserves the other keys" || fail "state_save_key preserves the other keys"
[ "$SAAS_GITLAB_STATE_REGISTRY_ENABLED" = "true" ] && pass "state_save_key preserves REGISTRY_ENABLED" || fail "state_save_key preserves REGISTRY_ENABLED"
[ "$SAAS_GITLAB_STATE_PAGES_ENABLED" = "false" ] && pass "state_save_key preserves PAGES_ENABLED" || fail "state_save_key preserves PAGES_ENABLED"
[ "$SAAS_GITLAB_STATE_PAGES_URL_MODE" = "subdomain" ] && pass "state_save_key preserves PAGES_URL_MODE" || fail "state_save_key preserves PAGES_URL_MODE"
[ "$SAAS_GITLAB_STATE_REDIS_PASSWORD" = "redispw123" ] && pass "state_save_key preserves REDIS_PASSWORD" || fail "state_save_key preserves REDIS_PASSWORD"
grep -q "^SAAS_GITLAB_STATE_REGISTRY_ENABLED=" "$(_saas_gitlab_state_path unittest)" \
    && pass "state_save_key: REGISTRY_ENABLED is actually present in the saved file" \
    || fail "state_save_key: REGISTRY_ENABLED is actually present in the saved file"

_saas_gitlab_state_delete "unittest"
_saas_gitlab_state_exists "unittest" && fail "state_delete removes the state" || pass "state_delete removes the state"

# Default release suggestion: no states -> 'gitlab'; exactly one -> that one.
[ "$(_saas_gitlab_suggest_release)" = "gitlab" ] && pass "suggest_release with no saved state -> 'gitlab'" || fail "suggest_release with no saved state -> 'gitlab'"
_saas_gitlab_state_save "only" "RELEASE=only"
[ "$(_saas_gitlab_suggest_release)" = "only" ] && pass "suggest_release with a single saved state -> that release" || fail "suggest_release with a single saved state -> that release"
_saas_gitlab_state_delete "only"

# ------------------------------------------------------------------
# StorageClass resolution (--cluster-mode existing)
# ------------------------------------------------------------------
kubectl() {
    if [ "$1" = "get" ] && [ "$2" = "storageclass" ]; then
        printf '%s\n' "${_TEST_SC_OUTPUT[@]}"
    fi
}

_TEST_SC_OUTPUT=("standard true")
[ "$(_saas_gitlab_resolve_storage_class "" false)" = "standard" ] && pass "storage-class: uses the one marked is-default-class" || fail "storage-class: uses the one marked is-default-class"

_TEST_SC_OUTPUT=("only-one ")
[ "$(_saas_gitlab_resolve_storage_class "" false)" = "only-one" ] && pass "storage-class: single existing one, unmarked, still used" || fail "storage-class: single existing one, unmarked"

_TEST_SC_OUTPUT=("zzz-class " "aaa-class ")
out="$(_saas_gitlab_resolve_storage_class "" true 2>/dev/null)"
[ "$out" = "aaa-class" ] && pass "storage-class: several, no default, non-interactive -> first alphabetically" || fail "storage-class: several, no default, non-interactive (got '$out')"

_TEST_SC_OUTPUT=()
_saas_gitlab_resolve_storage_class "" true >/dev/null 2>&1 && fail "storage-class: none at all, should fail" || pass "storage-class: no StorageClass at all, fails explicitly"

[ "$(_saas_gitlab_resolve_storage_class "explicit" true)" = "explicit" ] && pass "storage-class: an explicit one always wins" || fail "storage-class: an explicit one always wins"
unset -f kubectl

# ------------------------------------------------------------------
# Chart version resolution
# ------------------------------------------------------------------
helm() {
    case "$1 $2" in
        "repo list") echo '[{"name":"gitlab","url":"https://charts.gitlab.io"}]' ;;
        "repo update"|"repo add") : ;;
        "search repo")
            cat <<'JSON'
[{"name":"gitlab/gitlab","version":"10.3.1","app_version":"v19.3.1"},
 {"name":"gitlab/gitlab","version":"10.3.0","app_version":"v19.3.0"},
 {"name":"gitlab/gitlab","version":"10.2.5","app_version":"v19.2.5"}]
JSON
            ;;
    esac
}

[ "$(_saas_gitlab_version_resolve "latest")" = "10.3.1" ] && pass "version_resolve 'latest' -> the most recent" || fail "version_resolve 'latest'"
[ "$(_saas_gitlab_version_resolve "")" = "10.3.1" ] && pass "version_resolve empty -> the most recent" || fail "version_resolve empty"
[ "$(_saas_gitlab_version_resolve "10.2.5")" = "10.2.5" ] && pass "version_resolve an existing concrete version" || fail "version_resolve an existing concrete version"
_saas_gitlab_version_resolve "9.9.9" >/dev/null 2>&1 && fail "version_resolve a nonexistent version should fail" || pass "version_resolve a nonexistent version fails explicitly"
unset -f helm

# ------------------------------------------------------------------
# ssh-config: the generated block uses the saved domain/port
# ------------------------------------------------------------------
_saas_gitlab_state_save "sshtest" "RELEASE=sshtest" "CLUSTER_MODE=kind" \
    "DOMAIN=sshtest.gitlab.local" "SSH_HOST_PORT=2222"
out="$(_saas_gitlab_ssh_config sshtest 2>/dev/null)"
echo "$out" | grep -qx "Host sshtest.gitlab.local" && pass "ssh-config: block with the right Host" || fail "ssh-config: block with the right Host"
echo "$out" | grep -q "Port 2222" && pass "ssh-config: right port" || fail "ssh-config: right port"
echo "$out" | grep -q "User git" && pass "ssh-config: 'git' user" || fail "ssh-config: 'git' user"
_saas_gitlab_state_delete "sshtest"

# ------------------------------------------------------------------
# _saas_gitlab_certificate_request: the generated Certificate YAML's dnsNames must be quoted.
# Regression test for a real bug found manually (not by any test): an unquoted wildcard DOMAIN
# (e.g. "*.pages.<domain>", used by --pages-url-mode subdomain) made 'kubectl apply' fail with
# "error converting YAML to JSON: ... did not find expected alphabetic or numeric character",
# because a leading '*' is YAML's alias indicator when unquoted. Nothing exercised this function's
# generated YAML at all before, only real installs did (slow, and only for whichever combination
# happened to be run manually). This is the cheap, fast substitute: capture what actually gets
# piped to 'kubectl apply -f -' and assert each dnsName is wrapped in double quotes, both for a
# plain name (must keep working) and for a wildcard one (the case that broke).
# ------------------------------------------------------------------
_TEST_CERT_YAML=""
kubectl() {
    case "$*" in
        "-n testns apply -f -") _TEST_CERT_YAML="$(cat)" ;;
        "-n testns wait --for=condition=Ready --timeout=180s certificate/testcert") : ;;
    esac
}

_saas_gitlab_certificate_request "testns" "testcert" "gitlab.example.com" "test-issuer" "test-secret" "registry.example.com" >/dev/null 2>&1
echo "$_TEST_CERT_YAML" | grep -qF 'dnsNames: ["gitlab.example.com","registry.example.com"]' \
    && pass "certificate_request: plain dnsNames are quoted and comma-joined" \
    || fail "certificate_request: plain dnsNames are quoted and comma-joined (got: $(echo "$_TEST_CERT_YAML" | grep dnsNames))"

_saas_gitlab_certificate_request "testns" "testcert" "*.pages.example.com" "test-issuer" "test-secret" >/dev/null 2>&1
echo "$_TEST_CERT_YAML" | grep -qF 'dnsNames: ["*.pages.example.com"]' \
    && pass "certificate_request: a wildcard dnsName is quoted (the case that broke 'kubectl apply')" \
    || fail "certificate_request: a wildcard dnsName is quoted (got: $(echo "$_TEST_CERT_YAML" | grep dnsNames))"
unset -f kubectl

# ------------------------------------------------------------------
# DNS-01 provider dispatch: _saas_gitlab_issue_letsencrypt_dns01 must call the right issuer function
# for each provider (replaces the old "duckdns errors out" expectation now that it's implemented).
# ------------------------------------------------------------------
_TEST_DNS01_CALLED=""
_saas_gitlab_certmanager_issuer_letsencrypt_dns01_cloudflare() { _TEST_DNS01_CALLED="cloudflare:$1:$2:$3"; }
_saas_gitlab_certmanager_issuer_letsencrypt_dns01_duckdns()    { _TEST_DNS01_CALLED="duckdns:$1:$2:$3"; }

_saas_gitlab_issue_letsencrypt_dns01 "myissuer" "me@x.com" "tok1" "cloudflare"
[ "$_TEST_DNS01_CALLED" = "cloudflare:myissuer:me@x.com:tok1" ] && pass "dns01 dispatch: cloudflare calls the cloudflare issuer" || fail "dns01 dispatch: cloudflare calls the cloudflare issuer (got '$_TEST_DNS01_CALLED')"

_TEST_DNS01_CALLED=""
_saas_gitlab_issue_letsencrypt_dns01 "myissuer" "me@x.com" "tok2" "duckdns"
[ "$_TEST_DNS01_CALLED" = "duckdns:myissuer:me@x.com:tok2" ] && pass "dns01 dispatch: duckdns calls the duckdns issuer" || fail "dns01 dispatch: duckdns calls the duckdns issuer (got '$_TEST_DNS01_CALLED')"

_saas_gitlab_issue_letsencrypt_dns01 "myissuer" "me@x.com" "tok3" "route53" >/dev/null 2>&1 \
    && fail "dns01 dispatch: rejects an unsupported provider" || pass "dns01 dispatch: rejects an unsupported provider"
unset -f _saas_gitlab_certmanager_issuer_letsencrypt_dns01_cloudflare _saas_gitlab_certmanager_issuer_letsencrypt_dns01_duckdns

# ------------------------------------------------------------------
# _saas_gitlab_cluster_patch_coredns: variadic + idempotent replace (no duplication on a repeated
# call with the same domains; old entries replaced, not just appended, when the domain set changes).
# ------------------------------------------------------------------
# The Corefile "current state" is kept in a real FILE, not a shell variable: the mocked kubectl call
# that applies a new Corefile is the left side of a pipe ('kubectl create ... | kubectl apply -f -'),
# which bash always runs in a subshell. A plain variable assignment there would be lost the moment
# that subshell exits, but a write to a file survives it.
_TEST_COREFILE_FILE="$(mktemp)"
cat > "$_TEST_COREFILE_FILE" <<'EOF'
.:53 {
    errors
    kubernetes cluster.local {
       fallthrough
    }
}
EOF
kubectl() {
    case "$*" in
        "-n ingress-nginx get svc ingress-nginx-controller -o jsonpath={.spec.clusterIP}") echo "10.0.0.1" ;;
        "-n kube-system get configmap coredns -o jsonpath={.data.Corefile}") cat "$_TEST_COREFILE_FILE" ;;
        "-n kube-system create configmap coredns --from-file=Corefile="*)
            local path="$*"
            path="${path#*--from-file=Corefile=}"
            path="${path%% *}"
            cp "$path" "$_TEST_COREFILE_FILE"
            ;;
        "apply -f -") cat >/dev/null ;;
        "-n kube-system rollout restart deployment coredns") ;;
        "-n kube-system rollout status deployment coredns --timeout=60s") ;;
    esac
}

_saas_gitlab_cluster_patch_coredns "gitlab.local" "registry.gitlab.local" "pages.gitlab.local" >/dev/null 2>&1
first_run="$(cat "$_TEST_COREFILE_FILE")"
echo "$first_run" | grep -q "10.0.0.1 gitlab.local" && \
    echo "$first_run" | grep -q "10.0.0.1 registry.gitlab.local" && \
    echo "$first_run" | grep -q "10.0.0.1 pages.gitlab.local" \
    && pass "cluster_patch_coredns: all given domains are present" || fail "cluster_patch_coredns: all given domains are present"

_saas_gitlab_cluster_patch_coredns "gitlab.local" "registry.gitlab.local" "pages.gitlab.local" >/dev/null 2>&1
second_run="$(cat "$_TEST_COREFILE_FILE")"
[ "$(echo "$first_run" | grep -c "saas-gitlab-hosts-begin")" = "1" ] && [ "$(echo "$second_run" | grep -c "saas-gitlab-hosts-begin")" = "1" ] \
    && pass "cluster_patch_coredns: calling it again with the same domains doesn't duplicate the block" \
    || fail "cluster_patch_coredns: calling it again with the same domains doesn't duplicate the block"

_saas_gitlab_cluster_patch_coredns "gitlab.local" >/dev/null 2>&1
third_run="$(cat "$_TEST_COREFILE_FILE")"
echo "$third_run" | grep -q "registry.gitlab.local" && fail "cluster_patch_coredns: a smaller domain set replaces stale entries" \
    || pass "cluster_patch_coredns: a smaller domain set replaces stale entries"
unset -f kubectl
rm -f "$_TEST_COREFILE_FILE"

# ------------------------------------------------------------------
# _saas_gitlab_cluster_patch_coredns_pages_wildcard: independent block (CoreDNS 'template' plugin,
# for the arbitrary per-namespace Pages subdomains the 'hosts' plugin above can't match), toggled
# on/off cleanly, and coexisting with the 'hosts' block without interfering with it.
# ------------------------------------------------------------------
_TEST_COREFILE_FILE="$(mktemp)"
cat > "$_TEST_COREFILE_FILE" <<'EOF'
.:53 {
    errors
    kubernetes cluster.local {
       fallthrough
    }
}
EOF
kubectl() {
    case "$*" in
        "-n ingress-nginx get svc ingress-nginx-controller -o jsonpath={.spec.clusterIP}") echo "10.0.0.1" ;;
        "-n kube-system get configmap coredns -o jsonpath={.data.Corefile}") cat "$_TEST_COREFILE_FILE" ;;
        "-n kube-system create configmap coredns --from-file=Corefile="*)
            local path="$*"
            path="${path#*--from-file=Corefile=}"
            path="${path%% *}"
            cp "$path" "$_TEST_COREFILE_FILE"
            ;;
        "apply -f -") cat >/dev/null ;;
        "-n kube-system rollout restart deployment coredns") ;;
        "-n kube-system rollout status deployment coredns --timeout=60s") ;;
    esac
}

_saas_gitlab_cluster_patch_coredns_pages_wildcard "gitlab.local" true >/dev/null 2>&1
enabled_run="$(cat "$_TEST_COREFILE_FILE")"
echo "$enabled_run" | grep -q "template IN A pages.gitlab.local" && \
    echo "$enabled_run" | grep -q "10.0.0.1" \
    && pass "cluster_patch_coredns_pages_wildcard: template block present when enabled" \
    || fail "cluster_patch_coredns_pages_wildcard: template block present when enabled"

_saas_gitlab_cluster_patch_coredns_pages_wildcard "gitlab.local" false >/dev/null 2>&1
disabled_run="$(cat "$_TEST_COREFILE_FILE")"
echo "$disabled_run" | grep -q "saas-gitlab-pages-wildcard-begin" \
    && fail "cluster_patch_coredns_pages_wildcard: block removed when disabled" \
    || pass "cluster_patch_coredns_pages_wildcard: block removed when disabled"

# Coexistence: the 'hosts' block (exact names) and the 'template' wildcard block must both survive
# side by side, each keyed by its own markers, neither one clobbering the other.
_saas_gitlab_cluster_patch_coredns "gitlab.local" "registry.gitlab.local" >/dev/null 2>&1
_saas_gitlab_cluster_patch_coredns_pages_wildcard "gitlab.local" true >/dev/null 2>&1
both_run="$(cat "$_TEST_COREFILE_FILE")"
[ "$(echo "$both_run" | grep -c "saas-gitlab-hosts-begin")" = "1" ] && [ "$(echo "$both_run" | grep -c "saas-gitlab-pages-wildcard-begin")" = "1" ] \
    && pass "cluster_patch_coredns_pages_wildcard: coexists with the 'hosts' block, one of each" \
    || fail "cluster_patch_coredns_pages_wildcard: coexists with the 'hosts' block, one of each"
unset -f kubectl
rm -f "$_TEST_COREFILE_FILE"

# ------------------------------------------------------------------
# operators.sh: idempotent. 'helm upgrade --install' must not run again once the CRD/release is
# already present.
# ------------------------------------------------------------------
_TEST_HELM_CALLS=0
kubectl() {
    case "$*" in
        "get crd clusters.postgresql.cnpg.io") return 0 ;;
        "get crd redisreplications.redis.redis.opstreelabs.in") return 0 ;;
        *"create secret generic"*) : ;;
        "apply -f -") cat >/dev/null ;;
        *) return 1 ;;
    esac
}
helm() {
    case "$1" in
        upgrade) _TEST_HELM_CALLS=$((_TEST_HELM_CALLS + 1)) ;;
        status) return 0 ;;
    esac
}

_saas_gitlab_operator_cnpg_ensure >/dev/null 2>&1
_saas_gitlab_operator_redis_ensure >/dev/null 2>&1
_saas_gitlab_operator_duckdns_webhook_ensure "dummy-token" >/dev/null 2>&1
[ "$_TEST_HELM_CALLS" -eq 0 ] && pass "operators: already-present CNPG/redis-operator/duckdns-webhook skip 'helm upgrade --install'" \
    || fail "operators: already-present CNPG/redis-operator/duckdns-webhook skip 'helm upgrade --install' (got $_TEST_HELM_CALLS calls)"
unset -f kubectl helm

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
total="${#RESULTS[@]}"
failed=0
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL:* ]] && failed=$((failed + 1)); done
echo "Total: $total   Failed: $failed"
[ "$failed" -eq 0 ]
