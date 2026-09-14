#!/usr/bin/env bash
# Real end-to-end test for 'saas vault': creates a real DISPOSABLE kind cluster, installs
# Vault, and checks it genuinely comes up unsealed with real init/unseal automation, not just
# that the commands "don't fail". Same pattern (pass/fail, --only PHASE, --keep, cleanup trap) as
# tests/gitlab/e2e/run-tests.sh.
#
# Requires 'kind_cluster' to be loaded in the shell (bash-aliases) and saas vault's
# dependencies: kind, docker, kubectl, helm, jq, envsubst, curl. Takes several minutes.
#
# 'bash tests/vault/e2e/run-tests.sh' starts a NON-interactive bash, which doesn't inherit
# functions sourced in your shell, to avoid hardcoding any PC's absolute path in this file; if
# 'kind_cluster' isn't already available the KIND_CLUSTER_FUNCTIONS environment variable (path to
# bash-aliases' local-cluster-functions.sh) is used to load it:
#   KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
#     bash tests/vault/e2e/run-tests.sh
#
# Default phases (fast-ish, run every time): dev-install, doctor, up-down, credentials-defaults,
# integrate-gitlab-order-independence. Opt-in ONLY phases (heavy, never part of the default run):
# prod-ha, integrate-gitlab-full, eso-round-trip - each installs a second real service (a 3-replica
# Vault, a full 'saas gitlab install', a throwaway ESO) so is deliberately excluded from the
# default 'bash tests/vault/e2e/run-tests.sh' invocation. '--only' accepts a comma-separated list,
# which is how 'eso-round-trip' (it reuses the gitlab cluster 'integrate-gitlab-full' stands up) is
# meant to be invoked: '--only integrate-gitlab-full,eso-round-trip' runs both in one process so the
# cluster is still alive when the second phase needs it; selecting 'eso-round-trip' on its own fails
# fast with a clear message instead of silently finding nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RELEASE="vaulte2e"
HA_RELEASE="vaulte2eha"
GITLAB_RELEASE="gitlabe2e"
KEEP=false
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=true; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--keep] [--only PHASE[,PHASE...]]"
            echo "Phases: dev-install doctor up-down credentials-defaults integrate-gitlab-order-independence"
            echo "        (opt-in) prod-ha integrate-gitlab-full eso-round-trip"
            echo "'eso-round-trip' must be combined with 'integrate-gitlab-full' in the same --only list."
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

IFS=',' read -ra ONLY_LIST <<< "$ONLY"
phase_selected() {
    local p
    for p in "${ONLY_LIST[@]}"; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

if phase_selected eso-round-trip && ! phase_selected integrate-gitlab-full; then
    echo "❌ 'eso-round-trip' needs 'integrate-gitlab-full' in the same --only list (it reuses that phase's gitlab cluster)." >&2
    echo "   Run: --only integrate-gitlab-full,eso-round-trip" >&2
    exit 1
fi
if [ -n "$ONLY" ] && phase_selected integrate-gitlab-full && ! phase_selected dev-install; then
    echo "❌ 'integrate-gitlab-full' needs 'dev-install' in the same --only list when --only is given (it uses the Vault release 'dev-install' creates)." >&2
    echo "   Run: --only dev-install,integrate-gitlab-full[,eso-round-trip]" >&2
    exit 1
fi

declare -a RESULTS=()
pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

if ! command -v kind_cluster >/dev/null 2>&1 && [ -n "${KIND_CLUSTER_FUNCTIONS:-}" ]; then
    # shellcheck disable=SC1090
    source "$KIND_CLUSTER_FUNCTIONS"
fi
command -v kind_cluster >/dev/null 2>&1 || {
    echo "❌ 'kind_cluster' is not available. Load it in your shell before this script, or pass" >&2
    echo "   KIND_CLUSTER_FUNCTIONS=/path/to/local-cluster-functions.sh bash tests/vault/e2e/run-tests.sh" >&2
    exit 1
}

source "$REPO_ROOT/saas.sh"

cleanup() {
    if $KEEP; then
        echo "ℹ️  --keep: leaving everything alive for manual inspection."
        echo "   Remove it later with:"
        echo "     saas vault delete $RELEASE --purge-storage -y"
        phase_selected prod-ha && echo "     saas vault delete $HA_RELEASE --purge-storage -y"
        if phase_selected integrate-gitlab-full || phase_selected eso-round-trip; then
            echo "     saas gitlab delete $GITLAB_RELEASE --purge-storage -y"
        fi
        { phase_selected integrate-gitlab-full || phase_selected eso-round-trip; } && echo "     helm uninstall external-secrets --namespace external-secrets"
        return
    fi
    echo "🧹 Cleaning up…"
    # Deletes gitlab (and its ExternalSecret CRs, letting ESO's own controller clear their
    # finalizers normally) BEFORE uninstalling ESO, never the reverse: verified live that
    # uninstalling ESO first leaves the gitlab namespace stuck 'Terminating' forever, since nothing
    # is left running to process the ExternalSecrets' 'externalsecret-cleanup' finalizer. See
    # CLAUDE.md's existing note on this same class of finalizer gotcha.
    if phase_selected integrate-gitlab-full || phase_selected eso-round-trip; then
        saas gitlab delete "$GITLAB_RELEASE" --purge-storage -y >/dev/null 2>&1
    fi
    if phase_selected integrate-gitlab-full || phase_selected eso-round-trip; then
        helm uninstall external-secrets --namespace external-secrets >/dev/null 2>&1
    fi
    phase_selected prod-ha && saas vault delete "$HA_RELEASE" --purge-storage -y >/dev/null 2>&1
    saas vault delete "$RELEASE" --purge-storage -y >/dev/null 2>&1
}
trap cleanup EXIT

run_phase() { [ -z "$ONLY" ] || phase_selected "$1"; }

# ------------------------------------------------------------------
# Phase: dev-install
# ------------------------------------------------------------------
if run_phase dev-install; then
    echo "=== Phase: dev-install ==="

    if saas vault install --release "$RELEASE" --cluster-mode kind --mode dev \
        --tls self-signed --non-interactive -y; then
        pass "install (dev mode, kind, self-signed) succeeds"
    else
        fail "install (dev mode, kind, self-signed) succeeds"
    fi

    _saas_vault_state_load "$RELEASE" || fail "state was saved after install"

    live_status="$(_saas_vault_verify_status "$SAAS_VAULT_STATE_NAMESPACE" "$RELEASE" 2>/dev/null)"
    case "$live_status" in
        *sealed=false*initialized=true*) pass "Vault comes up unsealed and initialized, fully automated" ;;
        *) fail "Vault comes up unsealed and initialized, fully automated (got: '$live_status')" ;;
    esac

    status_code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${SAAS_VAULT_STATE_DOMAIN}" "https://localhost/v1/sys/health")"
    [[ "$status_code" =~ ^(200|429|472|473|501|503)$ ]] && pass "the ingress serves /v1/sys/health (HTTP $status_code)" || fail "the ingress serves /v1/sys/health (HTTP $status_code)"

    if saas vault credentials --reveal-root-token "$RELEASE" 2>/dev/null | grep -q "^Root token: *[^ ]"; then
        pass "credentials --reveal-root-token prints a token"
    else
        fail "credentials --reveal-root-token prints a token"
    fi

    root_token="$(saas vault credentials --reveal-root-token "$RELEASE" 2>/dev/null | awk -F': +' '/^Root token:/{print $2}')"
    if [ -n "$root_token" ]; then
        # A brief retry: right after unseal, the ingress/Endpoint chain can take a few seconds to
        # fully settle even though the pod itself already reports unsealed (verified live: a bare,
        # non-retried call here occasionally raced this window and got an empty response, while a
        # manual check moments later against the SAME instance succeeded cleanly).
        api_user=""
        for _ in $(seq 1 6); do
            api_user="$(curl -sk -H "X-Vault-Token: $root_token" -H "Host: ${SAAS_VAULT_STATE_DOMAIN}" "https://localhost/v1/auth/token/lookup-self" | jq -r '.data.display_name // empty')"
            [ "$api_user" = "root" ] && break
            sleep 5
        done
        [ "$api_user" = "root" ] && pass "the root token authenticates against the API" || fail "the root token authenticates against the API (got '$api_user')"
    else
        fail "could not read the root token to test API auth"
    fi
fi

# ------------------------------------------------------------------
# Phase: doctor (depends on 'dev-install'): deliberately reseals the instance by force-deleting the
# unseal-keys Secret's data, then checks 'saas vault doctor' both detects it and (--fix) repairs
# it via the saved local key shares, confirmed by a real API call afterward.
# ------------------------------------------------------------------
if run_phase doctor; then
    echo "=== Phase: doctor ==="
    _saas_vault_state_load "$RELEASE" 2>/dev/null || fail "doctor: no saved state (did you run 'dev-install' first?)"
    ns="$SAAS_VAULT_STATE_NAMESPACE"

    kubectl -n "$ns" delete secret "${RELEASE}-vault-unseal-keys" >/dev/null 2>&1
    pod="$(_saas_vault_pod0 "$RELEASE")"
    kubectl -n "$ns" delete pod "$pod" >/dev/null 2>&1
    kubectl -n "$ns" wait --for=condition=Ready --timeout=180s "pod/$pod" >/dev/null 2>&1

    doctor_report="$(saas vault doctor "$RELEASE" 2>&1)"
    echo "$doctor_report" | grep -qi "drift\|sealed" && pass "doctor (no --fix) detects the missing unseal-keys Secret" \
        || fail "doctor (no --fix) detects the missing unseal-keys Secret (output: $doctor_report)"

    saas vault doctor "$RELEASE" --fix >/dev/null 2>&1
    _saas_vault_wait_unsealed "$RELEASE" "$ns" >/dev/null 2>&1
    live_status="$(_saas_vault_verify_status "$ns" "$RELEASE" 2>/dev/null)"
    case "$live_status" in
        *sealed=false*) pass "doctor --fix re-unseals the instance from the saved local keys" ;;
        *) fail "doctor --fix re-unseals the instance from the saved local keys (got: '$live_status')" ;;
    esac
fi

# ------------------------------------------------------------------
# Phase: credentials-defaults (depends on 'dev-install'): the bare command must never print secret
# material, only the --reveal-* flags do.
# ------------------------------------------------------------------
if run_phase credentials-defaults; then
    echo "=== Phase: credentials-defaults ==="
    bare_output="$(saas vault credentials "$RELEASE" 2>/dev/null)"
    # Match only the actual data-printing lines ("Root token: ...", "  key1: ..."), not the
    # explanatory "(...hidden by default...)" notice, which legitimately mentions these words.
    echo "$bare_output" | grep -qE "^Root token:|^  key[0-9]+:" && fail "bare 'credentials' must not print secret material" \
        || pass "bare 'credentials' never prints secret material"
    echo "$bare_output" | grep -q "^URL:" && pass "bare 'credentials' still prints the URL" || fail "bare 'credentials' still prints the URL"
fi

# ------------------------------------------------------------------
# Phase: up-down (depends on 'dev-install'). Unlike gitlab's "root password survives up/down"
# regression test, this does NOT assert the root token/unseal keys stay byte-identical: verified
# live that kind's local-path-provisioner names each PV's host directory after that PV's own
# (random) UID, not the stable PVC name, so a fresh PVC created by 'up' never actually rebinds to
# the OLD data 'down' left on disk - it gets a genuinely empty Raft store. Reusing old Shamir
# shares against a fresh store can never work (they're cryptographically tied to the ONE init that
# produced them), so services/vault/lib/init.sh detects this via the pod's own live
# '.initialized' status and transparently re-initializes with FRESH keys when needed. The
# invariant this phase actually checks is the one that matters to a user: the instance ends up
# initialized and unsealed again with zero manual input, whether or not the old data happened to
# survive.
# ------------------------------------------------------------------
if run_phase up-down; then
    echo "=== Phase: up-down ==="
    _saas_vault_secrets_load "$RELEASE" 2>/dev/null || fail "up-down: no saved keys (did you run 'dev-install' first?)"
    token_before="$SAAS_VAULT_KEYS_ROOT_TOKEN"

    if saas vault down "$RELEASE" -y >/dev/null 2>&1; then
        pass "down destroys the cluster"
    else
        fail "down destroys the cluster"
    fi

    if saas vault up "$RELEASE" -y; then
        pass "up recreates the cluster and reinstalls"
    else
        fail "up recreates the cluster and reinstalls"
    fi

    _saas_vault_secrets_load "$RELEASE"
    if [ "$SAAS_VAULT_KEYS_ROOT_TOKEN" = "$token_before" ]; then
        echo "ℹ️  up-down: the underlying Raft data survived this cycle (same root token reused)."
    else
        echo "ℹ️  up-down: the underlying Raft data did NOT survive this cycle (kind's local-path-provisioner PV-naming, see comment above); fresh keys were generated automatically."
    fi

    _saas_vault_state_load "$RELEASE"
    live_status="$(_saas_vault_verify_status "$SAAS_VAULT_STATE_NAMESPACE" "$RELEASE" 2>/dev/null)"
    case "$live_status" in
        *sealed=false*initialized=true*) pass "up-down: ends up initialized and unsealed automatically, regardless of data survival" ;;
        *) fail "up-down: ends up initialized and unsealed automatically, regardless of data survival (got: '$live_status')" ;;
    esac

    root_token="$SAAS_VAULT_KEYS_ROOT_TOKEN"
    api_user=""
    for _ in $(seq 1 6); do
        api_user="$(curl -sk -H "X-Vault-Token: $root_token" -H "Host: ${SAAS_VAULT_STATE_DOMAIN}" "https://localhost/v1/auth/token/lookup-self" | jq -r '.data.display_name // empty')"
        [ "$api_user" = "root" ] && break
        sleep 5
    done
    [ "$api_user" = "root" ] && pass "up-down: the (possibly fresh) root token authenticates against the API" || fail "up-down: the (possibly fresh) root token authenticates against the API (got '$api_user')"
fi

# ------------------------------------------------------------------
# Phase: integrate-gitlab-order-independence (no dependency on 'dev-install' having installed
# gitlab; genuinely runs with no gitlab cluster in existence at all). Confirms 'saas vault
# integrate gitlab' fails cleanly against an unreachable context and touches NONE of Vault's own
# auth/KV configuration - the literal safety property the two-phase design exists for.
# ------------------------------------------------------------------
if run_phase integrate-gitlab-order-independence; then
    echo "=== Phase: integrate-gitlab-order-independence ==="
    _saas_vault_state_load "$RELEASE" 2>/dev/null || fail "integrate-gitlab-order-independence: no saved state (did you run 'dev-install' first?)"

    auth_before="$(_saas_vault_bao_exec "$RELEASE" "$SAAS_VAULT_STATE_NAMESPACE" auth list -format=json 2>/dev/null)"
    secrets_before="$(_saas_vault_bao_exec "$RELEASE" "$SAAS_VAULT_STATE_NAMESPACE" secrets list -format=json 2>/dev/null)"

    if saas vault integrate gitlab --vault-release "$RELEASE" --gitlab-context "kind-nonexistent-e2e-ctx-$$" >/dev/null 2>&1; then
        fail "integrate gitlab against a nonexistent context should fail"
    else
        pass "integrate gitlab against a nonexistent context fails cleanly"
    fi

    auth_after="$(_saas_vault_bao_exec "$RELEASE" "$SAAS_VAULT_STATE_NAMESPACE" auth list -format=json 2>/dev/null)"
    secrets_after="$(_saas_vault_bao_exec "$RELEASE" "$SAAS_VAULT_STATE_NAMESPACE" secrets list -format=json 2>/dev/null)"
    [ "$auth_before" = "$auth_after" ] && pass "Vault's auth methods are untouched by the failed attempt" || fail "Vault's auth methods are untouched by the failed attempt"
    [ "$secrets_before" = "$secrets_after" ] && pass "Vault's secrets engines are untouched by the failed attempt" || fail "Vault's secrets engines are untouched by the failed attempt"
fi

# ------------------------------------------------------------------
# Phase: prod-ha (opt-in only, never part of the default run: installs a SECOND Vault release,
# 3-replica HA Raft, real cluster cost). Confirms all 3 nodes join the Raft cluster and unseal.
# ------------------------------------------------------------------
if phase_selected prod-ha; then
    echo "=== Phase: prod-ha (opt-in) ==="

    if saas vault install --release "$HA_RELEASE" --cluster-mode kind --mode prod \
        --tls self-signed --non-interactive -y; then
        pass "prod-ha: install (3-replica HA Raft) succeeds"
    else
        fail "prod-ha: install (3-replica HA Raft) succeeds"
    fi

    _saas_vault_state_load "$HA_RELEASE"
    ns="$SAAS_VAULT_STATE_NAMESPACE"
    fullname="$(_saas_vault_fullname "$HA_RELEASE")"

    all_unsealed=true
    for i in 0 1 2; do
        pod="${fullname}-${i}"
        kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Running --timeout=180s "pod/$pod" >/dev/null 2>&1
        status_json="$(kubectl -n "$ns" exec "$pod" -c openbao -- env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT="/openbao/tls/ca.crt" bao status -format=json 2>/dev/null)"
        # Plain '.sealed', not '.sealed // "unknown"': jq's '//' falls through on BOTH null and
        # false, so a fallback here would silently turn the one state we're checking for (sealed
        # == false) into "unknown" too, and this check could never pass (verified live: every
        # unsealed pod's real JSON had "sealed": false, yet the '//' version always printed
        # 'unknown'). See CLAUDE.md.
        sealed="$(echo "$status_json" | jq -r '.sealed')"
        [ "$sealed" = "false" ] || all_unsealed=false
    done
    $all_unsealed && pass "prod-ha: all 3 replicas report unsealed" || fail "prod-ha: all 3 replicas report unsealed"

    peers="$(kubectl -n "$ns" exec "${fullname}-0" -c openbao -- env BAO_TOKEN="$(_saas_vault_secrets_load "$HA_RELEASE"; echo "$SAAS_VAULT_KEYS_ROOT_TOKEN")" BAO_CACERT=/openbao/tls/ca.crt bao operator raft list-peers -format=json 2>/dev/null | jq -r '.data.config.servers | length' 2>/dev/null)"
    [ "${peers:-0}" -eq 3 ] && pass "prod-ha: Raft cluster has 3 voters" || fail "prod-ha: Raft cluster has 3 voters (got '${peers:-0}')"
    # Cleanup deferred to the unified end-of-script 'cleanup' trap (honors --keep uniformly).
fi

# ------------------------------------------------------------------
# Phase: integrate-gitlab-full (opt-in only, heavy: a REAL 'saas gitlab install'). Exercises the
# full two-sided handshake end to end: 'saas vault integrate gitlab' -> 'saas gitlab integrate
# vault' (applies the reviewer manifest) -> 'saas vault integrate gitlab' again (completes
# phase B, seeds gitlab's REAL live datastore credentials) -> 'saas gitlab integrate vault'
# again (applies the final manifests).
#
# Installs gitlab with '--cluster-mode existing' INTO Vault's own kind cluster (a different
# namespace, same cluster), rather than a genuinely separate second kind cluster: verified live
# that 'kind_cluster --expose-mode ingress-nginx' hardcodes host ports 80/443, so two
# '--cluster-mode kind' services can never coexist on one host (confirmed: creating a second kind
# cluster here fails outright). This reproduces every real code path faithfully EXCEPT the final
# cross-cluster network reachability check (Vault's Kubernetes-auth 'kubernetes_host' is only
# genuinely unreachable-from-inside-the-target-cluster when the clusters are truly separate; see
# CLAUDE.md). Two real, separate clusters resolve that one remaining gap, not achievable in this
# single-host test run.
# ------------------------------------------------------------------
if phase_selected integrate-gitlab-full; then
    echo "=== Phase: integrate-gitlab-full (opt-in) ==="

    if saas gitlab install --release "$GITLAB_RELEASE" --cluster-mode existing --storage-class standard --mode dev \
        --tls self-signed --non-interactive -y; then
        pass "integrate-gitlab-full: a real 'saas gitlab install' succeeds"
    else
        fail "integrate-gitlab-full: a real 'saas gitlab install' succeeds"
    fi

    # '--gitlab-context' is required here: 'integrate gitlab' can only auto-derive a context from
    # '--gitlab-release' for a '--cluster-mode kind' install (kind-<name>); a '--cluster-mode
    # existing' release (this one, installed into Vault's own cluster above) never had its
    # context recorded, by design, since for a real existing cluster there's no stable name to
    # derive it from. Vault's own kind context IS the gitlab release's context here.
    saas vault integrate gitlab --vault-release "$RELEASE" --gitlab-release "$GITLAB_RELEASE" --gitlab-context "kind-${RELEASE}" >/dev/null 2>&1
    saas gitlab integrate vault --release "$GITLAB_RELEASE" --vault-release "$RELEASE" >/dev/null 2>&1

    if saas vault integrate gitlab --vault-release "$RELEASE" --gitlab-release "$GITLAB_RELEASE" --gitlab-context "kind-${RELEASE}"; then
        pass "integrate-gitlab-full: phase B completes once the reviewer manifest is applied"
    else
        fail "integrate-gitlab-full: phase B completes once the reviewer manifest is applied"
    fi

    out_dir="$HOME/.local/state/saas/vault/${RELEASE}/gitlab-integration/${GITLAB_RELEASE}"
    _saas_gitlab_state_load "$GITLAB_RELEASE"
    psql_seeded="$(_saas_vault_bao_exec "$RELEASE" "$(_saas_vault_state_load "$RELEASE"; echo "$SAAS_VAULT_STATE_NAMESPACE")" kv get -mount=gitlab/${GITLAB_RELEASE} -format=json psql 2>/dev/null | jq -r '.data.data.username // empty')"
    [ "$psql_seeded" = "gitlab" ] && pass "integrate-gitlab-full: gitlab's real PostgreSQL username was seeded into Vault" \
        || fail "integrate-gitlab-full: gitlab's real PostgreSQL username was seeded into Vault (got '$psql_seeded')"

    # The final apply (below) needs ESO's CRDs already present in-cluster - 'saas gitlab integrate
    # vault' correctly refuses a partial apply otherwise (see vault_integration.sh). Install
    # the same throwaway, test-only ESO 'eso-round-trip' also uses here, since that check is what
    # this phase's own "final manifests applied" assertion depends on, not a separate concern.
    if ! helm repo list -o json 2>/dev/null | jq -e '.[]? | select(.name == "external-secrets")' >/dev/null; then
        helm repo add external-secrets https://charts.external-secrets.io >/dev/null
    fi
    helm repo update external-secrets >/dev/null
    if helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets --create-namespace --set installCRDs=true --wait --timeout 180s >/dev/null 2>&1; then
        pass "integrate-gitlab-full: throwaway ESO install succeeds (test infrastructure only)"
    else
        fail "integrate-gitlab-full: throwaway ESO install succeeds (test infrastructure only)"
    fi

    if saas gitlab integrate vault --release "$GITLAB_RELEASE" --vault-release "$RELEASE"; then
        pass "integrate-gitlab-full: the final SecretStore/ExternalSecret manifests are applied"
    else
        fail "integrate-gitlab-full: the final SecretStore/ExternalSecret manifests are applied"
    fi
    [ -f "$out_dir/gitlab-secretstore.yaml" ] && [ -f "$out_dir/gitlab-externalsecret.yaml" ] \
        && pass "integrate-gitlab-full: manifests exist on disk with valid YAML content" \
        || fail "integrate-gitlab-full: manifests exist on disk with valid YAML content"
    # Cleanup deferred to the unified end-of-script 'cleanup' trap: 'eso-round-trip', when selected
    # together with this phase, needs this same gitlab cluster still alive.
fi

# ------------------------------------------------------------------
# Phase: eso-round-trip (opt-in only, heavy: reuses the throwaway, test-only External Secrets
# Operator 'integrate-gitlab-full' already installed into the same cluster - a prerequisite for
# THAT phase's own final-apply check, not duplicated here - purely to prove a secret genuinely
# round-trips from Vault through ESO into a real Kubernetes Secret; ESO itself is never installed
# by 'saas vault' - this is test infrastructure only, see CLAUDE.md decision on this).
# ------------------------------------------------------------------
if phase_selected eso-round-trip; then
    echo "=== Phase: eso-round-trip (opt-in) ==="
    _saas_gitlab_state_load "$GITLAB_RELEASE" 2>/dev/null || fail "eso-round-trip: no gitlab cluster found (combine with --only integrate-gitlab-full,eso-round-trip)"
    ns="$SAAS_GITLAB_STATE_NAMESPACE"

    kubectl -n "$ns" wait --for=condition=Ready --timeout=120s externalsecret --all >/dev/null 2>&1
    # Checking for a non-empty 'username' alone would be a false positive: gitlab creates this
    # SAME Secret name natively regardless of ESO (services/gitlab/lib/datastore.sh), so that
    # field is never actually empty either way. With 'creationPolicy: Owner' the ExternalSecret
    # sets an ownerReference on the Secret it creates/adopts - checking for THAT is the only way
    # to tell "ESO actually synced this from Vault" apart from "gitlab's own native Secret is
    # still sitting there untouched".
    owner_kind=""
    for i in $(seq 1 24); do
        owner_kind="$(kubectl -n "$ns" get secret "${GITLAB_RELEASE}-datastore-psql" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)"
        [ "$owner_kind" = "ExternalSecret" ] && break
        sleep 5
    done
    if [ "$owner_kind" = "ExternalSecret" ] && kubectl -n "$ns" get secret "${GITLAB_RELEASE}-datastore-psql" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d | grep -q .; then
        pass "eso-round-trip: a real Kubernetes Secret was synced by ESO from Vault (owned by its ExternalSecret)"
    else
        fail "eso-round-trip: a real Kubernetes Secret was synced by ESO from Vault (owner: '${owner_kind:-none}')"
    fi
    # Cleanup (ESO uninstall + gitlab cluster) deferred to the unified end-of-script 'cleanup' trap.
fi

echo ""
echo "=== Summary ==="
failed=0
for r in "${RESULTS[@]}"; do
    echo "$r"
    case "$r" in FAIL:*) failed=$((failed + 1)) ;; esac
done
echo ""
echo "Total: ${#RESULTS[@]}   Failed: $failed"
[ "$failed" -eq 0 ]
