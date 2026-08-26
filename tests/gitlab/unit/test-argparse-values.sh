#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas gitlab: validators, StorageClass/version resolution, persistent state, ~/.ssh/config snippet generation. Mocks kubectl/helm/kind_cluster by shadowing functions — same pattern as tests/kind-cluster/test-suggest-target.sh in the sibling bash-aliases repo. Does not replace the real E2E suite (tests/gitlab/e2e/).
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
source "$REPO_ROOT/services/gitlab/lib/tls.sh"
source "$REPO_ROOT/services/gitlab/lib/ssh.sh"
source "$REPO_ROOT/services/gitlab/lib/credentials.sh"

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

# ------------------------------------------------------------------
# Persistent state: roundtrip, including values with spaces/quotes
# ------------------------------------------------------------------
_saas_gitlab_state_save "unittest" "RELEASE=unittest" "NAMESPACE=unittest" \
    "DOMAIN=unittest.gitlab.local" "PSQL_PASSWORD=p@ss w/ spaces \"and quotes\"" "STATUS=up"

if _saas_gitlab_state_load "unittest"; then
    [ "$SAAS_GITLAB_STATE_RELEASE" = "unittest" ] && pass "state roundtrip: RELEASE" || fail "state roundtrip: RELEASE (got '$SAAS_GITLAB_STATE_RELEASE')"
    [ "$SAAS_GITLAB_STATE_DOMAIN" = "unittest.gitlab.local" ] && pass "state roundtrip: DOMAIN" || fail "state roundtrip: DOMAIN"
    [ "$SAAS_GITLAB_STATE_PSQL_PASSWORD" = 'p@ss w/ spaces "and quotes"' ] && pass "state roundtrip: value with spaces/quotes" || fail "state roundtrip: value with spaces/quotes (got '$SAAS_GITLAB_STATE_PSQL_PASSWORD')"
else
    fail "state roundtrip: could not load the just-saved state"
fi

_saas_gitlab_state_exists "unittest" && pass "state_exists detects a saved state" || fail "state_exists detects a saved state"
_saas_gitlab_state_exists "does-not-exist" && fail "state_exists doesn't detect a nonexistent state" || pass "state_exists doesn't detect a nonexistent state"

_saas_gitlab_state_save_key "unittest" "STATUS" "down" >/dev/null
_saas_gitlab_state_load "unittest"
[ "$SAAS_GITLAB_STATE_STATUS" = "down" ] && pass "state_save_key updates a single key" || fail "state_save_key updates a single key"
[ "$SAAS_GITLAB_STATE_DOMAIN" = "unittest.gitlab.local" ] && pass "state_save_key preserves the other keys" || fail "state_save_key preserves the other keys"

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
# Summary
# ------------------------------------------------------------------
echo ""
total="${#RESULTS[@]}"
failed=0
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL:* ]] && failed=$((failed + 1)); done
echo "Total: $total   Failed: $failed"
[ "$failed" -eq 0 ]
