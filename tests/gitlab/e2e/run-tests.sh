#!/usr/bin/env bash
# Real end-to-end test for 'saas gitlab': creates a real DISPOSABLE kind
# cluster, installs GitLab in dev mode with self-signed TLS, and checks
# that it genuinely serves traffic, that the credentials are correct, and
# that the runner ends up registered — not just that the commands "don't
# fail". Same pattern (pass/fail, --only PHASE, --keep, cleanup trap) as
# tests/kind-cluster/run-tests.sh in the sibling bash-aliases repo.
#
# Requires 'kind_cluster' to be loaded in the shell (bash-aliases) and
# saas gitlab's dependencies: kind, docker, kubectl, helm, jq, envsubst,
# curl. Takes several minutes (installs GitLab for real).
#
# 'bash tests/gitlab/e2e/run-tests.sh' starts a NON-interactive bash,
# which doesn't inherit functions sourced in your shell (even if
# kind_cluster is already loaded where you launch it from) — to avoid
# hardcoding any PC's absolute path in this file, if 'kind_cluster' isn't
# already available the KIND_CLUSTER_FUNCTIONS environment variable
# (path to bash-aliases' local-cluster-functions.sh) is used to load it:
#   KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
#     bash tests/gitlab/e2e/run-tests.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RELEASE="saase2e"
KEEP=false
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=true; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--keep] [--only dev-install|up-down|ssh-config]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

declare -a RESULTS=()
pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

if ! command -v kind_cluster >/dev/null 2>&1 && [ -n "${KIND_CLUSTER_FUNCTIONS:-}" ]; then
    # shellcheck disable=SC1090
    source "$KIND_CLUSTER_FUNCTIONS"
fi
command -v kind_cluster >/dev/null 2>&1 || {
    echo "❌ 'kind_cluster' is not available. Load it in your shell before this script, or pass" >&2
    echo "   KIND_CLUSTER_FUNCTIONS=/path/to/local-cluster-functions.sh bash tests/gitlab/e2e/run-tests.sh" >&2
    exit 1
}

source "$REPO_ROOT/saas.sh"

cleanup() {
    if $KEEP; then
        echo "ℹ️  --keep: leaving '$RELEASE' alive for manual inspection."
        echo "   Remove it later with: saas gitlab delete $RELEASE --purge-storage -y"
        return
    fi
    echo "🧹 Cleaning up…"
    saas gitlab delete "$RELEASE" --purge-storage -y >/dev/null 2>&1
}
trap cleanup EXIT

run_phase() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ------------------------------------------------------------------
# Phase: dev-install
# ------------------------------------------------------------------
if run_phase dev-install; then
    echo "=== Phase: dev-install ==="

    if saas gitlab install --release "$RELEASE" --cluster-mode kind --mode dev \
        --tls self-signed --kind-workers 0 --non-interactive -y; then
        pass "install (dev mode, kind, self-signed) succeeds"
    else
        fail "install (dev mode, kind, self-signed) succeeds"
    fi

    _saas_gitlab_state_load "$RELEASE" || { fail "state was saved after install"; }

    status_code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${SAAS_GITLAB_STATE_DOMAIN:-$RELEASE.gitlab.local}" "https://localhost/users/sign_in")"
    [[ "$status_code" =~ ^(200|302)$ ]] && pass "the ingress serves /users/sign_in (HTTP $status_code)" || fail "the ingress serves /users/sign_in (HTTP $status_code)"

    password="$(saas gitlab credentials "$RELEASE" 2>/dev/null | awk '/^Password:/{print $2}')"
    [ -n "$password" ] && [ "$password" != "" ] && pass "credentials prints a root password" || fail "credentials prints a root password"

    if kubectl -n "$RELEASE" get deployment "${RELEASE}-runner-gitlab-runner" >/dev/null 2>&1; then
        ready="$(kubectl -n "$RELEASE" get deployment "${RELEASE}-runner-gitlab-runner" -o jsonpath='{.status.readyReplicas}')"
        [ "${ready:-0}" -ge 1 ] 2>/dev/null && pass "GitLab Runner deployed with ready replicas" || fail "GitLab Runner deployed but no ready replicas"
    else
        fail "GitLab Runner deployed"
    fi
fi

# ------------------------------------------------------------------
# Phase: up-down (depends on 'dev-install' having left the release alive
# — either run the full suite, or 'dev-install --keep' first if running
# just this phase with --only)
# ------------------------------------------------------------------
if run_phase up-down; then
    echo "=== Phase: up-down ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "up-down: no saved state (did you run 'dev-install' first?)"; }

    root_password_before="$SAAS_GITLAB_STATE_ROOT_PASSWORD"

    if saas gitlab down "$RELEASE" -y; then
        pass "down destroys the cluster"
    else
        fail "down destroys the cluster"
    fi

    kind get clusters -q 2>/dev/null | grep -qx "$SAAS_GITLAB_STATE_KIND_NAME" \
        && fail "down: the kind cluster no longer exists" || pass "down: the kind cluster no longer exists"

    if saas gitlab up "$RELEASE"; then
        pass "up recreates the cluster and reinstalls"
    else
        fail "up recreates the cluster and reinstalls"
    fi

    _saas_gitlab_state_load "$RELEASE"
    [ "$SAAS_GITLAB_STATE_ROOT_PASSWORD" = "$root_password_before" ] && pass "up: the root password stays the same across the cycle" || fail "up: the root password stays the same across the cycle"

    status_code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $SAAS_GITLAB_STATE_DOMAIN" "https://localhost/users/sign_in")"
    [[ "$status_code" =~ ^(200|302)$ ]] && pass "after 'up', the ingress serves /users/sign_in again" || fail "after 'up', the ingress serves /users/sign_in again (HTTP $status_code)"
fi

# ------------------------------------------------------------------
# Phase: ssh-config
# ------------------------------------------------------------------
if run_phase ssh-config; then
    echo "=== Phase: ssh-config ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "ssh-config: no saved state (did you run 'dev-install' first?)"; }

    out="$(saas gitlab ssh-config "$RELEASE" 2>/dev/null)"
    echo "$out" | grep -q "Host $SAAS_GITLAB_STATE_DOMAIN" && pass "ssh-config prints the block for the right domain" || fail "ssh-config prints the block for the right domain"

    if command -v nc >/dev/null 2>&1; then
        nc -z -w3 127.0.0.1 "$SAAS_GITLAB_STATE_SSH_HOST_PORT" && pass "the SSH port exposed on the host accepts connections" || fail "the SSH port exposed on the host accepts connections"
    fi
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "=== Summary ==="
failed=0
for r in "${RESULTS[@]}"; do
    echo "$r"
    [[ "$r" == FAIL:* ]] && failed=$((failed + 1))
done
echo ""
echo "Total: ${#RESULTS[@]}   Failed: $failed"
[ "$failed" -eq 0 ]
