#!/usr/bin/env bash
# Real end-to-end test for 'saas gitlab': creates a real DISPOSABLE kind
# cluster, installs GitLab in dev mode with self-signed TLS, and checks
# that it genuinely serves traffic, that the credentials are correct, and
# that the runner ends up registered, not just that the commands "don't
# fail". Same pattern (pass/fail, --only PHASE, --keep, cleanup trap) as
# tests/kind-cluster/run-tests.sh in the sibling bash-aliases repo.
#
# Requires 'kind_cluster' to be loaded in the shell (bash-aliases) and
# saas gitlab's dependencies: kind, docker, kubectl, helm, jq, envsubst,
# curl. Takes several minutes (installs GitLab for real).
#
# 'bash tests/gitlab/e2e/run-tests.sh' starts a NON-interactive bash,
# which doesn't inherit functions sourced in your shell (even if
# kind_cluster is already loaded where you launch it from), to avoid
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
# Pinned like every other test/runtime image in this repo (see CLAUDE.md, "Pinned versions"); the
# 'debug' variant is a busybox-based image with a shell, needed to chain 'crane auth login' and the
# actual push/pull in one container invocation. Verified against ghcr.io/gcr.io at time of writing.
CRANE_IMAGE="gcr.io/go-containerregistry/crane/debug:v0.22.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=true; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--keep] [--only dev-install|registry-push-pull|reinstall|registry|pages|duckdns|up-down|ssh-config|prod-ha|pages-subdomain]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

declare -a RESULTS=()
pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

# _e2e_curl_in_cluster NAMESPACE POD_NAME URL
# Prints the HTTP status code of an in-cluster curl (or empty on failure/timeout). Deliberately NOT
# 'kubectl run --rm -i ... -- curl' + command substitution: reproduced live, on a real cluster,
# that pattern silently loses the output when the command finishes fast (a few ms, e.g. a 401 with
# no body). 'kubectl run --rm -i's attach can lose the race against the container exiting. Reading
# the result back via 'kubectl logs' after the pod reaches a terminal phase isn't subject to that
# race (logs are stored by the kubelet independently of any client attach), so this is used for
# every ad-hoc in-cluster HTTP check in this suite instead.
_e2e_curl_in_cluster() {
    local ns="$1" pod="$2" url="$3"
    kubectl -n "$ns" run "$pod" --restart=Never --image=curlimages/curl:8.11.0 -- \
        sh -c "curl -sk -o /dev/null -w '%{http_code}' '$url'" >/dev/null 2>&1
    kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=30s "pod/$pod" >/dev/null 2>&1
    kubectl -n "$ns" logs "$pod" 2>/dev/null
    kubectl -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null 2>&1
}

# _e2e_registry_ca NAMESPACE RELEASE OUT_FILE
# Extracts the release's self-signed cert into OUT_FILE, the same Secret 'saas gitlab credentials'
# already documents for real users (credentials.sh) to trust it. Fails if empty/missing.
_e2e_registry_ca() {
    local ns="$1" release="$2" out="$3"
    kubectl -n "$ns" get secret "${release}-gitlab-tls" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$out"
    [ -s "$out" ]
}

# _e2e_crane WORKDIR REGISTRY_HOST DOMAIN ROOT_PASSWORD CRANE_COMMAND
# Runs a throwaway 'crane' container FROM THE HOST (--network host + --add-host, no /etc/hosts or
# Docker daemon changes), exactly like a real remote 'docker pull' would reach the kind-exposed
# hostPort. Deliberately not an in-cluster pod: a pod inside the cluster can already reach MinIO's
# ClusterIP directly either way, so only a client outside the pod network actually exercises
# 'redirect.disable' (datastore.sh). Needs BOTH hostnames resolvable, not just REGISTRY_HOST:
# reproduced live that GitLab's registry auth flow (401 on /v2/ -> Www-Authenticate: Bearer
# realm="https://DOMAIN/jwt/auth") sends the client to fetch its bearer token from the MAIN domain,
# not the registry subdomain. TLS trust comes from WORKDIR/ca.crt (see _e2e_registry_ca) via
# SSL_CERT_FILE, not from installing anything into the host's real trust store. Output (both
# 'auth login' and CRANE_COMMAND) is appended to WORKDIR/crane.log for post-mortem on failure.
_e2e_crane() {
    local work_dir="$1" registry_host="$2" domain="$3" root_password="$4" cmd="$5"
    docker run --rm --network host \
        --add-host "${registry_host}:127.0.0.1" \
        --add-host "${domain}:127.0.0.1" \
        -e SSL_CERT_FILE=/work/ca.crt \
        -v "$work_dir:/work" \
        --entrypoint sh "$CRANE_IMAGE" \
        -c "crane auth login '$registry_host' -u root -p '$root_password' && $cmd" \
        >>"$work_dir/crane.log" 2>&1
    local status=$?
    [ "$status" -eq 0 ] || cat "$work_dir/crane.log"
    return "$status"
}

# _e2e_registry_ensure_project NAMESPACE RELEASE
# GitLab's Container Registry authorizes a push/pull only against a repository path that maps to a
# REAL project (reproduced live: pushing to a made-up path like 'registry/e2e-smoke' 401s even with
# valid credentials, "authentication required", since the JWT auth service has nothing to check
# scope against). Creates 'root/e2e-smoke' if missing, via 'gitlab-rails runner' in the toolbox pod,
# the same bootstrap pattern '_saas_gitlab_runner_mint_root_pat' (runner.sh) already uses.
_e2e_registry_ensure_project() {
    local ns="$1" release="$2"
    local toolbox_pod
    toolbox_pod="$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep -m1 "${release}-toolbox" | sed 's#^pod/##')"
    [ -n "$toolbox_pod" ] || return 1

    local script='
u = User.find_by_username("root")
p = Project.find_by_full_path("root/e2e-smoke")
unless p
  p = ::Projects::CreateService.new(u, name: "e2e-smoke", path: "e2e-smoke", visibility_level: Gitlab::VisibilityLevel::PRIVATE, container_registry_enabled: true).execute
  raise p.errors.full_messages.join(", ") unless p.persisted?
end
puts p.full_path
'
    kubectl -n "$ns" exec "$toolbox_pod" -- gitlab-rails runner "$script" 2>/dev/null | grep -qx "root/e2e-smoke"
}

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
        --tls self-signed --kind-workers 0 --pages --non-interactive -y; then
        pass "install (dev mode, kind, self-signed, registry+pages) succeeds"
    else
        fail "install (dev mode, kind, self-signed, registry+pages) succeeds"
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
# Phase: registry-push-pull (depends on 'dev-install'; a REAL image push+pull against the Container
# Registry, from OUTSIDE the cluster's pod network, see _e2e_crane above. This is what actually
# exercises 'pathstyle'/'checksum_disabled'/'redirect.disable' on the registry's S3 storage config
# against MinIO (datastore.sh); the 'registry' phase below only proves the API is reachable, not
# that a real push/pull works end to end.)
# ------------------------------------------------------------------
if run_phase registry-push-pull; then
    echo "=== Phase: registry-push-pull ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "registry-push-pull: no saved state (did you run 'dev-install' first?)"; }

    ns="${SAAS_GITLAB_STATE_NAMESPACE:-$RELEASE}"
    domain="${SAAS_GITLAB_STATE_DOMAIN:-}"
    registry_host="registry.${domain}"
    image_ref="${registry_host}/root/e2e-smoke:latest"
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/saas-e2e-registry-XXXXXX")"

    if ! _e2e_registry_ensure_project "$ns" "$RELEASE"; then
        fail "registry-push-pull: could not create the 'root/e2e-smoke' project to push into"
    elif _e2e_registry_ca "$ns" "$RELEASE" "$work_dir/ca.crt"; then
        tar cf "$work_dir/layer.tar" -C "$REPO_ROOT" README.md

        if _e2e_crane "$work_dir" "$registry_host" "$domain" "$SAAS_GITLAB_STATE_ROOT_PASSWORD" \
            "crane append -f /work/layer.tar -t '$image_ref' --oci-empty-base"; then
            pass "crane push of a real image to the Container Registry from outside the cluster succeeds"
        else
            fail "crane push of a real image to the Container Registry from outside the cluster succeeds (see $work_dir/crane.log)"
        fi

        if _e2e_crane "$work_dir" "$registry_host" "$domain" "$SAAS_GITLAB_STATE_ROOT_PASSWORD" \
            "crane pull '$image_ref' /work/pulled.tar" && [ -s "$work_dir/pulled.tar" ]; then
            pass "crane pull of the same image from outside the cluster succeeds"
        else
            fail "crane pull of the same image from outside the cluster succeeds (see $work_dir/crane.log)"
        fi
    else
        fail "registry-push-pull: could not extract the self-signed CA from ${RELEASE}-gitlab-tls"
    fi
    rm -rf "$work_dir"
fi

# ------------------------------------------------------------------
# Phase: reinstall (depends on 'dev-install' AND 'registry-push-pull': re-runs 'saas gitlab install'
# a SECOND time against the already-provisioned $RELEASE, the exact scenario Bug 1 fixed (install
# used to regenerate PostgreSQL/MinIO/root/Redis credentials on every call, even against a live
# release, desyncing them from the already-running pods, see install.sh). Confirms the four
# credentials are byte-identical before/after, and re-pulls the image pushed above: the real
# functional proof that the MinIO credentials baked into the registry's storage Secret are still the
# ones the already-running MinIO pod actually accepts, not just that the state file's password
# string didn't change.
# ------------------------------------------------------------------
if run_phase reinstall; then
    echo "=== Phase: reinstall ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "reinstall: no saved state (did you run 'dev-install' first?)"; }

    ns="${SAAS_GITLAB_STATE_NAMESPACE:-$RELEASE}"
    psql_before="$SAAS_GITLAB_STATE_PSQL_PASSWORD"
    minio_user_before="$SAAS_GITLAB_STATE_MINIO_ROOT_USER"
    minio_password_before="$SAAS_GITLAB_STATE_MINIO_ROOT_PASSWORD"
    root_password_before="$SAAS_GITLAB_STATE_ROOT_PASSWORD"

    if saas gitlab install --release "$RELEASE" --cluster-mode kind --mode dev \
        --tls self-signed --kind-workers 0 --pages --non-interactive -y; then
        pass "a second 'install' against the already-provisioned release succeeds"
    else
        fail "a second 'install' against the already-provisioned release succeeds"
    fi

    _saas_gitlab_state_load "$RELEASE"
    [ "$SAAS_GITLAB_STATE_PSQL_PASSWORD" = "$psql_before" ] && pass "reinstall: PSQL_PASSWORD unchanged" || fail "reinstall: PSQL_PASSWORD unchanged"
    [ "$SAAS_GITLAB_STATE_MINIO_ROOT_USER" = "$minio_user_before" ] && pass "reinstall: MINIO_ROOT_USER unchanged" || fail "reinstall: MINIO_ROOT_USER unchanged"
    [ "$SAAS_GITLAB_STATE_MINIO_ROOT_PASSWORD" = "$minio_password_before" ] && pass "reinstall: MINIO_ROOT_PASSWORD unchanged" || fail "reinstall: MINIO_ROOT_PASSWORD unchanged"
    [ "$SAAS_GITLAB_STATE_ROOT_PASSWORD" = "$root_password_before" ] && pass "reinstall: ROOT_PASSWORD unchanged" || fail "reinstall: ROOT_PASSWORD unchanged"

    status_code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $SAAS_GITLAB_STATE_DOMAIN" "https://localhost/users/sign_in")"
    [[ "$status_code" =~ ^(200|302)$ ]] && pass "after reinstall, the ingress still serves /users/sign_in" || fail "after reinstall, the ingress still serves /users/sign_in (HTTP $status_code)"

    registry_host="registry.${SAAS_GITLAB_STATE_DOMAIN}"
    image_ref="${registry_host}/root/e2e-smoke:latest"
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/saas-e2e-reinstall-XXXXXX")"

    if _e2e_registry_ca "$ns" "$RELEASE" "$work_dir/ca.crt" \
        && _e2e_crane "$work_dir" "$registry_host" "$SAAS_GITLAB_STATE_DOMAIN" "$SAAS_GITLAB_STATE_ROOT_PASSWORD" "crane pull '$image_ref' /work/pulled.tar" \
        && [ -s "$work_dir/pulled.tar" ]; then
        pass "the image pushed earlier is still pullable after reinstall (MinIO auth intact)"
    else
        fail "the image pushed earlier is still pullable after reinstall (MinIO auth intact, see $work_dir/crane.log)"
    fi
    rm -rf "$work_dir"
fi

# ------------------------------------------------------------------
# Phase: registry (depends on 'dev-install' having left the release alive; --registry is on by
# default, so this checks the Container Registry endpoint is genuinely reachable, not just that the
# chart install/-wait succeeded)
# ------------------------------------------------------------------
if run_phase registry; then
    echo "=== Phase: registry ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "registry: no saved state (did you run 'dev-install' first?)"; }

    status_code="$(_e2e_curl_in_cluster "$RELEASE" "saas-e2e-registry-check-$$" "https://registry.${SAAS_GITLAB_STATE_DOMAIN}/v2/")"
    [[ "$status_code" =~ ^(200|401)$ ]] && pass "the registry API responds at registry.<domain>/v2/ (HTTP $status_code)" \
        || fail "the registry API responds at registry.<domain>/v2/ (HTTP $status_code)"
fi

# ------------------------------------------------------------------
# Phase: pages (depends on 'dev-install' having installed with --pages)
# ------------------------------------------------------------------
if run_phase pages; then
    echo "=== Phase: pages ==="
    _saas_gitlab_state_load "$RELEASE" 2>/dev/null || { fail "pages: no saved state (did you run 'dev-install' first?)"; }

    if kubectl -n "$RELEASE" get deployment "${RELEASE}-gitlab-pages" >/dev/null 2>&1; then
        ready="$(kubectl -n "$RELEASE" get deployment "${RELEASE}-gitlab-pages" -o jsonpath='{.status.readyReplicas}')"
        [ "${ready:-0}" -ge 1 ] 2>/dev/null && pass "GitLab Pages deployed with ready replicas" || fail "GitLab Pages deployed but no ready replicas"
    else
        fail "GitLab Pages deployed"
    fi

    status_code="$(_e2e_curl_in_cluster "$RELEASE" "saas-e2e-pages-check-$$" "https://pages.${SAAS_GITLAB_STATE_DOMAIN}/")"
    # Any real HTTP response (even 404, since no project has published Pages yet) proves it's reachable,
    # as opposed to connection-refused/timeout.
    [[ "$status_code" =~ ^[0-9]{3}$ ]] && pass "pages.<domain> is reachable (HTTP $status_code)" \
        || fail "pages.<domain> is reachable (HTTP $status_code)"
fi

# ------------------------------------------------------------------
# Phase: duckdns (independent of 'dev-install'; does NOT attempt real ACME issuance, since there's
# no real DuckDNS account/domain in CI; only exercises the webhook's own Helm/RBAC wiring with a
# dummy token. Full DNS-01 issuance against DuckDNS can only be verified manually.)
# ------------------------------------------------------------------
if run_phase duckdns; then
    echo "=== Phase: duckdns ==="

    if _saas_gitlab_operator_duckdns_webhook_ensure "dummy-token-for-e2e"; then
        pass "the DuckDNS cert-manager webhook installs successfully"
    else
        fail "the DuckDNS cert-manager webhook installs successfully"
    fi

    ready="$(kubectl -n cert-manager get deployment cert-manager-webhook-duckdns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${ready:-0}" -ge 1 ] 2>/dev/null && pass "the DuckDNS webhook Deployment has ready replicas" || fail "the DuckDNS webhook Deployment has ready replicas"

    kubectl get apiservice -o name 2>/dev/null | grep -q "acme.duckdns.org" \
        && pass "the DuckDNS webhook APIService is registered" || fail "the DuckDNS webhook APIService is registered"
fi

# ------------------------------------------------------------------
# Phase: up-down (depends on 'dev-install' having left the release alive:
# either run the full suite, or 'dev-install --keep' first if running
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
# Phase: prod-ha, OPT-IN ONLY, never part of the default full-suite run (must be requested
# explicitly with --only prod-ha). 3x CNPG PostgreSQL + 3x Redis (+3x Sentinel) + 4x MinIO + the full
# 'prod' mode GitLab resource baseline (~8 vCPU/16GB) is too heavy for most laptops/CI runners to run
# alongside the rest of the suite. Uses a SEPARATE release so it doesn't interfere with $RELEASE.
# ------------------------------------------------------------------
if [ "$ONLY" = "prod-ha" ]; then
    echo "=== Phase: prod-ha (opt-in, heavy) ==="
    HA_RELEASE="saase2eha"
    # This phase is the only one in the file that can reach 'set -u' with a genuinely unset
    # variable (SAAS_GITLAB_STATE_DOMAIN is never persisted until the FULL install succeeds, see
    # install.sh, the early vs. final _saas_gitlab_state_save calls, so a failed install leaves it
    # unset). 'set -u' EXITS THE WHOLE SCRIPT on that, not just this block, which would skip
    # cleanup entirely and leave the kind cluster running (reproduced live). Every reference below
    # is guarded with ':-' for that reason, but as a second line of defense this phase also takes
    # over the EXIT trap for the rest of the script's life (safe: this is the last phase in the
    # file, and it's mutually exclusive with every other phase; '--only prod-ha' runs nothing else
    # in the same invocation, so the top-of-file 'cleanup' trap, which only ever touches $RELEASE,
    # has nothing left to do here anyway).
    trap 'saas gitlab delete "$HA_RELEASE" --purge-storage -y >/dev/null 2>&1' EXIT
    prod_ha_phase() {
    if saas gitlab install --release "$HA_RELEASE" --cluster-mode kind --mode prod \
        --tls self-signed --force-self-signed-prod --kind-workers 0 --non-interactive -y; then
        pass "install (prod mode, kind, self-signed) succeeds"
    else
        fail "install (prod mode, kind, self-signed) succeeds"
    fi

    _saas_gitlab_state_load "$HA_RELEASE" 2>/dev/null || { fail "prod-ha: no saved state after install"; return; }
    ns="${SAAS_GITLAB_STATE_NAMESPACE:-$HA_RELEASE}"

    instances="$(kubectl -n "$ns" get "cluster.postgresql.cnpg.io/${HA_RELEASE}-postgresql" -o jsonpath='{.status.instances}' 2>/dev/null)"
    [ "${instances:-0}" -eq 3 ] 2>/dev/null && pass "CloudNativePG cluster has 3 instances" || fail "CloudNativePG cluster has 3 instances (got '${instances:-0}')"

    # NOT 'kubectl wait --for=condition=Ready': verified live that neither RedisReplication nor
    # RedisSentinel expose a 'conditions' field in this redis-operator version, so that wait hangs
    # to its timeout regardless of actual health. Check the underlying StatefulSets instead (same
    # fix applied in datastore-ha.sh).
    redis_ready="$(kubectl -n "$ns" get statefulset "${HA_RELEASE}-redis" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${redis_ready:-0}" -eq 3 ] 2>/dev/null && pass "Redis StatefulSet has 3 ready replicas" || fail "Redis StatefulSet has 3 ready replicas (got '${redis_ready:-0}')"
    sentinel_ready="$(kubectl -n "$ns" get statefulset "${HA_RELEASE}-redis-sentinel" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${sentinel_ready:-0}" -eq 3 ] 2>/dev/null && pass "Redis Sentinel StatefulSet has 3 ready replicas" || fail "Redis Sentinel StatefulSet has 3 ready replicas (got '${sentinel_ready:-0}')"

    minio_ready="$(kubectl -n "$ns" get statefulset "${HA_RELEASE}-minio" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${minio_ready:-0}" -eq 4 ] 2>/dev/null && pass "MinIO distributed StatefulSet has 4 ready replicas" || fail "MinIO distributed StatefulSet has 4 ready replicas (got '${minio_ready:-0}')"

    [ -n "${SAAS_GITLAB_STATE_DOMAIN:-}" ] || { fail "the ingress serves /users/sign_in (install never completed, no domain persisted)"; return; }
    status_code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $SAAS_GITLAB_STATE_DOMAIN" "https://localhost/users/sign_in")"
    [[ "$status_code" =~ ^(200|302)$ ]] && pass "the ingress serves /users/sign_in (HTTP $status_code)" || fail "the ingress serves /users/sign_in (HTTP $status_code)"
    }
    prod_ha_phase
    saas gitlab delete "$HA_RELEASE" --purge-storage -y >/dev/null 2>&1
    trap - EXIT
fi

# ------------------------------------------------------------------
# Phase: pages-subdomain, OPT-IN ONLY, never part of the default full-suite run (must be requested
# explicitly with --only pages-subdomain). A second full GitLab install with its own release/domain,
# so it doesn't interfere with $RELEASE's own 'pages' phase above (which stays on the default 'path'
# URL mode). Only exercises the --tls self-signed side of --pages-url-mode subdomain: unlike
# --tls letsencrypt --challenge dns01, it needs no real DNS provider account at all (a self-signed
# ClusterIssuer signs a wildcard SAN locally, no CA validation involved), the same reason the
# 'duckdns' phase above can't attempt real ACME issuance in CI either. The letsencrypt+dns01 path
# can only be verified manually (see README.md's --pages-url-mode example).
#
# '127.0.0.1.nip.io' as --domain resolves any subdomain to the host's own loopback address with zero
# setup (see CLAUDE.md's "Pages TLS decision"), which is what makes this phase runnable in CI: no
# DNS to configure, no account, nothing external.
# ------------------------------------------------------------------
if [ "$ONLY" = "pages-subdomain" ]; then
    echo "=== Phase: pages-subdomain (opt-in) ==="
    SUB_RELEASE="saase2epagessub"
    # Same 'set -u' guard rationale as the prod-ha phase above: state isn't persisted until a full
    # install succeeds, so this phase takes over the EXIT trap for its own duration.
    trap 'saas gitlab delete "$SUB_RELEASE" --purge-storage -y >/dev/null 2>&1' EXIT
    pages_subdomain_phase() {
    if saas gitlab install --release "$SUB_RELEASE" --cluster-mode kind --mode dev \
        --tls self-signed --domain 127.0.0.1.nip.io --kind-workers 0 \
        --pages --pages-url-mode subdomain --non-interactive -y; then
        pass "install (self-signed, --pages-url-mode subdomain) succeeds"
    else
        fail "install (self-signed, --pages-url-mode subdomain) succeeds"
    fi

    _saas_gitlab_state_load "$SUB_RELEASE" 2>/dev/null || { fail "pages-subdomain: no saved state after install"; return; }
    ns="${SAAS_GITLAB_STATE_NAMESPACE:-$SUB_RELEASE}"

    kubectl -n "$ns" get certificate "${SUB_RELEASE}-gitlab-pages-wildcard-cert" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True \
        && pass "the wildcard Pages Certificate is Ready" || fail "the wildcard Pages Certificate is Ready"

    kubectl -n "$ns" get secret "${SUB_RELEASE}-gitlab-pages-wildcard-tls" >/dev/null 2>&1 \
        && pass "the wildcard Pages Secret exists, separate from the main one" \
        || fail "the wildcard Pages Secret exists, separate from the main one"

    kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null \
        | grep -q "saas-gitlab-pages-wildcard-begin" \
        && pass "the CoreDNS wildcard template block is present" \
        || fail "the CoreDNS wildcard template block is present"

    status_code="$(_e2e_curl_in_cluster "$ns" "saas-e2e-pages-subdomain-check-$$" "https://somegroup.pages.127.0.0.1.nip.io/")"
    # Same "any real HTTP response proves it's reachable" logic as the 'pages' phase above: no
    # project has published a Pages site under this made-up namespace, so a 404 is expected and fine.
    [[ "$status_code" =~ ^[0-9]{3}$ ]] && pass "a Pages subdomain (somegroup.pages.<domain>) is reachable (HTTP $status_code)" \
        || fail "a Pages subdomain (somegroup.pages.<domain>) is reachable (HTTP $status_code)"
    }
    pages_subdomain_phase
    saas gitlab delete "$SUB_RELEASE" --purge-storage -y >/dev/null 2>&1
    trap - EXIT
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
