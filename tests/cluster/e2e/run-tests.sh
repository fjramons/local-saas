#!/usr/bin/env bash
# Real end-to-end test for 'saas cluster': creates real kind clusters to check multi-cluster,
# LoadBalancer (MetalLB) with no IP collision between clusters, persistent multi-node storage in
# both its modes (local-path with the manual nodeAffinity workaround, nfs with no workaround) with
# real content verification (not just that the pod goes back to Ready), and the
# create/delete/create lifecycle (idempotency + purge-storage).
#
# Complements tests/cluster/unit/test-argparse-values.sh (unit, no real clusters, for the default-
# cluster suggestion logic and validators). Same pattern (pass/fail, --only PHASE, --keep, cleanup
# trap) as tests/gitlab/e2e/run-tests.sh and the sibling bash-aliases repo's own
# tests/kind-cluster/run-tests.sh, which this suite is a self-contained port of (v1.0, see
# CLAUDE.md's Design notes for services/cluster/).
#
# Requires the same dependencies as 'saas cluster': kind, docker, kubectl, helm, envsubst, jq.
# Takes several minutes (creates real kind clusters).
#
# Usage:
#   tests/cluster/e2e/run-tests.sh [--keep] [--only PHASE]
#
#   --keep         Don't delete the test clusters at the end (for inspection)
#   --only PHASE   Run only one phase: multi-cluster | lb | storage-local-path |
#                  storage-nfs | idempotency | port-map | fault-injection | ingress |
#                  gateway-api | expose
#
# See also: .claude/skills/test-saas-cluster/SKILL.md
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

source "$REPO_ROOT/saas.sh"

CLUSTER_A="sce2e-foo"
CLUSTER_B="sce2e-bar"
CLUSTER_C="sce2e-idem"
CLUSTER_D="sce2e-portmap"
CLUSTER_E="sce2e-fault"
CLUSTER_F="sce2e-ingress"
CLUSTER_G="sce2e-gateway"
CLUSTER_H="sce2e-expose"
KEEP=false
ONLY=""

declare -a RESULTS=()

pass() { RESULTS+=("PASS  $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "❌ FAIL: $1"; }

should_run() {
    [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)      KEEP=true; shift ;;
        --only)      ONLY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--keep] [--only multi-cluster|lb|storage-local-path|storage-nfs|idempotency|port-map|fault-injection|ingress|gateway-api|expose]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

cleanup() {
    if $KEEP; then
        echo ""
        echo "ℹ️  --keep given: not deleting the test clusters."
        return
    fi
    echo ""
    echo "🧹 Cleaning up test clusters..."
    # Only stdout is silenced (kind's routine "Deleting cluster ..."); stderr is left to pass
    # through so retry warnings are visible if docker is slow to release a container, so the
    # script doesn't look hung. Each cluster may already have been explicitly deleted by its own
    # phase (e.g. storage-nfs, idempotency, and fault-injection assert 'delete' themselves); its
    # existence is checked first so the output isn't cluttered with an expected "doesn't exist".
    local c
    for c in "$CLUSTER_A" "$CLUSTER_B" "$CLUSTER_C" "$CLUSTER_D" "$CLUSTER_E" "$CLUSTER_F" "$CLUSTER_G" "$CLUSTER_H"; do
        kind get clusters -q 2>/dev/null | grep -qx "$c" && saas cluster delete "$c" --yes >/dev/null
    done
}
trap cleanup EXIT

_wait_for_lb_ip() {
    local ctx="$1" ip="" tries=0
    while [ "$tries" -lt 30 ]; do
        ip="$(kubectl --context "$ctx" get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
        [ -n "$ip" ] && break
        sleep 2
        tries=$((tries + 1))
    done
    printf '%s' "$ip"
}

phase_multi_cluster() {
    should_run multi-cluster || return 0
    echo ""
    echo "=== Phase: multi-cluster ==="

    # Both clusters are created WITHOUT LoadBalancer for now (installed in the 'lb' phase, once
    # both already exist and are stable) - not because MetalLB causes the contention (confirmed
    # it does NOT: the second cluster also fails with no MetalLB involved), but to isolate
    # variables. The real observed failure is that the second cluster's kubeadm/etcd can fail to
    # respond in time right when the first one has just started; a real gap is given between the
    # two creations to let it settle.
    saas cluster create --name "$CLUSTER_A" --workers 2 --storage-mode local-path --no-loadbalancer --yes \
        && pass "create cluster ${CLUSTER_A} (local-path, 2 workers)" \
        || { fail "create cluster ${CLUSTER_A}"; return 1; }

    echo "⏳ Waiting 60s for ${CLUSTER_A} to settle before creating ${CLUSTER_B}..."
    sleep 60

    saas cluster create --name "$CLUSTER_B" --workers 2 --storage-mode nfs --no-loadbalancer --yes \
        && pass "create cluster ${CLUSTER_B} (nfs, 2 workers)" \
        || { fail "create cluster ${CLUSTER_B}"; return 1; }

    if kind get clusters -q | grep -qx "$CLUSTER_A" && kind get clusters -q | grep -qx "$CLUSTER_B"; then
        pass "both clusters show up in 'kind get clusters'"
    else
        fail "both clusters show up in 'kind get clusters'"
    fi

    if kubectl config get-contexts -o name | grep -qx "kind-${CLUSTER_A}" \
        && kubectl config get-contexts -o name | grep -qx "kind-${CLUSTER_B}"; then
        pass "contexts kind-${CLUSTER_A}/kind-${CLUSTER_B} present"
    else
        fail "contexts kind-${CLUSTER_A}/kind-${CLUSTER_B} present"
    fi

    if saas cluster list 2>&1 | grep -q "$CLUSTER_A"; then
        pass "'saas cluster list' lists ${CLUSTER_A}"
    else
        fail "'saas cluster list' lists ${CLUSTER_A}"
    fi

    local status_output
    status_output="$(saas cluster status "$CLUSTER_A" 2>&1)"
    if printf '%s' "$status_output" | grep -q "control-plane"; then
        pass "'saas cluster status' lists the cluster's nodes"
    else
        fail "'saas cluster status' lists the cluster's nodes (output: ${status_output})"
    fi

    saas cluster use "$CLUSTER_A" >/dev/null 2>&1 && pass "'saas cluster use' switches context" || fail "'saas cluster use' switches context"
}

phase_lb() {
    should_run lb || return 0
    echo ""
    echo "=== Phase: LoadBalancer (MetalLB) ==="

    saas cluster deploy-loadbalancer "$CLUSTER_A" --yes >/dev/null \
        && pass "'saas cluster deploy-loadbalancer' installs MetalLB on ${CLUSTER_A}" \
        || { fail "'saas cluster deploy-loadbalancer' on ${CLUSTER_A}"; return 1; }

    saas cluster deploy-loadbalancer "$CLUSTER_B" --yes >/dev/null \
        && pass "'saas cluster deploy-loadbalancer' installs MetalLB on ${CLUSTER_B}" \
        || { fail "'saas cluster deploy-loadbalancer' on ${CLUSTER_B}"; return 1; }

    kubectl --context "kind-${CLUSTER_A}" apply -f - < "${MANIFESTS_DIR}/loadbalancer-test.yaml" >/dev/null \
        && kubectl --context "kind-${CLUSTER_B}" apply -f - < "${MANIFESTS_DIR}/loadbalancer-test.yaml" >/dev/null \
        && pass "LoadBalancer manifest applied on both clusters" \
        || { fail "apply LoadBalancer manifest"; return 1; }

    kubectl --context "kind-${CLUSTER_A}" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1
    kubectl --context "kind-${CLUSTER_B}" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1

    local ip_a ip_b
    ip_a="$(_wait_for_lb_ip "kind-${CLUSTER_A}")"
    ip_b="$(_wait_for_lb_ip "kind-${CLUSTER_B}")"

    if [ -n "$ip_a" ]; then pass "EXTERNAL-IP assigned on ${CLUSTER_A}: ${ip_a}"; else fail "EXTERNAL-IP assigned on ${CLUSTER_A}"; fi
    if [ -n "$ip_b" ]; then pass "EXTERNAL-IP assigned on ${CLUSTER_B}: ${ip_b}"; else fail "EXTERNAL-IP assigned on ${CLUSTER_B}"; fi

    if [ -n "$ip_a" ] && [ -n "$ip_b" ] && [ "$ip_a" != "$ip_b" ]; then
        pass "${CLUSTER_A}/${CLUSTER_B}'s IP ranges don't collide"
    else
        fail "${CLUSTER_A}/${CLUSTER_B}'s IP ranges don't collide"
    fi

    if [ -n "$ip_a" ] && curl -s -m 5 "http://${ip_a}" | grep -qi "nginx"; then
        pass "curl to ${ip_a} responds (nginx)"
    else
        fail "curl to ${ip_a} responds"
    fi
    if [ -n "$ip_b" ] && curl -s -m 5 "http://${ip_b}" | grep -qi "nginx"; then
        pass "curl to ${ip_b} responds (nginx)"
    else
        fail "curl to ${ip_b} responds"
    fi
}

phase_storage_local_path() {
    should_run storage-local-path || return 0
    echo ""
    echo "=== Phase: multi-node storage (local-path, ${CLUSTER_A}) ==="

    local ctx="kind-${CLUSTER_A}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/statefulset-storage-test.yaml" >/dev/null \
        && pass "StatefulSet applied on ${CLUSTER_A}" || { fail "apply StatefulSet on ${CLUSTER_A}"; return 1; }

    kubectl --context "$ctx" wait --for=condition=ready --timeout=90s pod/writer-0 >/dev/null 2>&1 \
        && pass "writer-0 is Ready" || { fail "writer-0 is Ready"; return 1; }

    local node marker_before
    node="$(kubectl --context "$ctx" get pod writer-0 -o jsonpath='{.spec.nodeName}')"
    echo "   writer-0 scheduled on: ${node}"
    marker_before="$(kubectl --context "$ctx" exec writer-0 -- cat /data/marker 2>/dev/null)"

    kubectl --context "$ctx" cordon "$node" >/dev/null
    kubectl --context "$ctx" delete pod writer-0 >/dev/null
    sleep 5

    local phase
    phase="$(kubectl --context "$ctx" get pod writer-0 -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [ "$phase" = "Pending" ]; then
        pass "writer-0 stays Pending after rescheduling (expected nodeAffinity limitation, not a real failure)"
    else
        fail "writer-0 stays Pending after rescheduling (expected Pending, got '${phase}')"
    fi

    # Uncordoning should get the pod scheduled back on the SAME node (it's the only one with the
    # PV that matches its nodeAffinity) and, if the data genuinely survived, the marker must
    # contain the EXACT same value as before - not just "the pod went back to Ready" (that would
    # also happen with a fresh, empty volume: see the manifest's own comment).
    kubectl --context "$ctx" uncordon "$node" >/dev/null 2>&1
    if kubectl --context "$ctx" wait --for=condition=ready --timeout=60s pod/writer-0 >/dev/null 2>&1; then
        local marker_after
        marker_after="$(kubectl --context "$ctx" exec writer-0 -- cat /data/marker 2>/dev/null)"
        if [ -n "$marker_before" ] && [ "$marker_after" = "$marker_before" ]; then
            pass "data survives on the same node after uncordoning (marker unchanged: ${marker_after})"
        else
            fail "data survives on the same node after uncordoning (before: '${marker_before}', after: '${marker_after}')"
        fi
    else
        fail "writer-0 goes back to Ready when its original node is uncordoned"
    fi
}

phase_storage_nfs() {
    should_run storage-nfs || return 0
    echo ""
    echo "=== Phase: multi-node storage (nfs, ${CLUSTER_B}) ==="

    local ctx="kind-${CLUSTER_B}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/statefulset-storage-test.yaml" >/dev/null \
        && pass "StatefulSet applied on ${CLUSTER_B}" || { fail "apply StatefulSet on ${CLUSTER_B}"; return 1; }

    kubectl --context "$ctx" wait --for=condition=ready --timeout=90s pod/writer-0 >/dev/null 2>&1 \
        && pass "writer-0 is Ready" || { fail "writer-0 is Ready"; return 1; }

    local node marker_before
    node="$(kubectl --context "$ctx" get pod writer-0 -o jsonpath='{.spec.nodeName}')"
    echo "   writer-0 scheduled on: ${node}"
    marker_before="$(kubectl --context "$ctx" exec writer-0 -- cat /data/marker 2>/dev/null)"

    kubectl --context "$ctx" cordon "$node" >/dev/null
    kubectl --context "$ctx" delete pod writer-0 >/dev/null
    kubectl --context "$ctx" wait --for=condition=ready --timeout=90s pod/writer-0 >/dev/null 2>&1 \
        && pass "writer-0 reschedules directly, no Pending, no fix needed (nfs mode)" \
        || fail "writer-0 reschedules directly, no Pending, no fix needed (nfs mode)"

    local new_node
    new_node="$(kubectl --context "$ctx" get pod writer-0 -o jsonpath='{.spec.nodeName}')"
    if [ -n "$new_node" ] && [ "$new_node" != "$node" ]; then
        pass "writer-0 rescheduled onto a different node (${node} -> ${new_node})"
    else
        fail "writer-0 rescheduled onto a different node (got node: '${new_node:-empty}')"
    fi

    # It's not enough for the pod to go back to Ready on another node: it must be confirmed to be
    # the SAME data (same marker value), not a fresh, empty volume that would also, coincidentally,
    # leave the pod Ready.
    local marker_after
    marker_after="$(kubectl --context "$ctx" exec writer-0 -- cat /data/marker 2>/dev/null)"
    if [ -n "$marker_before" ] && [ "$marker_after" = "$marker_before" ]; then
        pass "data survives rescheduling onto another node (marker unchanged: ${marker_after})"
    else
        fail "data survives rescheduling onto another node (before: '${marker_before}', after: '${marker_after}')"
    fi

    kubectl --context "$ctx" uncordon "$node" >/dev/null 2>&1

    # This cluster (no longer needed for later phases) is reused to explicitly assert 'saas
    # cluster delete --purge-storage', instead of leaving the deletion to the silent cleanup trap:
    # it's the storage mode (nfs, a privileged container) where the purge can hit root-owned files
    # on the host - exactly the case the "docker run" fallback in services/cluster/lib/delete.sh
    # exercises.
    if saas cluster delete "$CLUSTER_B" --yes --purge-storage >/dev/null 2>&1; then
        pass "'saas cluster delete --purge-storage' on ${CLUSTER_B} (nfs mode) succeeds"
    else
        fail "'saas cluster delete --purge-storage' on ${CLUSTER_B} (nfs mode) succeeds"
    fi

    local storage_dir="${SAAS_CLUSTER_STORAGE_DIR:-$HOME/.local/share/kind-cluster}"
    if [ ! -e "${storage_dir}/${CLUSTER_B}" ]; then
        pass "'--purge-storage' genuinely deletes '${storage_dir}/${CLUSTER_B}' (root-owned files included)"
    else
        fail "'--purge-storage' genuinely deletes '${storage_dir}/${CLUSTER_B}' (it still exists)"
    fi
}

phase_idempotency() {
    should_run idempotency || return 0
    echo ""
    echo "=== Phase: create -> delete -> create idempotency (${CLUSTER_C}) ==="

    # A minimal cluster (no workers, no LoadBalancer) on purpose: this phase doesn't test
    # MetalLB/storage (already covered elsewhere), only that 'delete' genuinely frees the
    # name/context/network for reuse, and that each step's exit code is reliable enough to chain
    # in scripts with '&&'.
    saas cluster create --name "$CLUSTER_C" --workers 0 --no-loadbalancer --yes >/dev/null 2>&1 \
        && pass "first creation of ${CLUSTER_C}" || { fail "first creation of ${CLUSTER_C}"; return 1; }

    saas cluster delete "$CLUSTER_C" --yes >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_C}" || { fail "deletion of ${CLUSTER_C}"; return 1; }

    if kind get clusters -q 2>/dev/null | grep -qx "$CLUSTER_C"; then
        fail "${CLUSTER_C} no longer shows up in 'kind get clusters' after deletion"
    else
        pass "${CLUSTER_C} no longer shows up in 'kind get clusters' after deletion"
    fi

    # The real idempotency test: recreating with the SAME name must work with no leftover from the
    # previous cycle (kubectl context, docker network, storage directory) blocking creation.
    saas cluster create --name "$CLUSTER_C" --workers 0 --no-loadbalancer --yes >/dev/null 2>&1 \
        && pass "recreating ${CLUSTER_C} with the same name after deleting it" \
        || fail "recreating ${CLUSTER_C} with the same name after deleting it"

    saas cluster delete "$CLUSTER_C" --yes --purge-storage >/dev/null 2>&1 \
        && pass "final deletion of ${CLUSTER_C} (with --purge-storage)" \
        || fail "final deletion of ${CLUSTER_C} (with --purge-storage)"
}

phase_port_map() {
    should_run port-map || return 0
    echo ""
    echo "=== Phase: --port-map (${CLUSTER_D}) ==="

    # A minimal cluster (no workers, no LoadBalancer) with a host port mapped to the manifest's
    # fixed NodePort (30080). Unlike inspecting 'docker port' (which would only prove the
    # extraPortMappings YAML was rendered correctly), this checks that real traffic reaches the pod
    # through the Docker -> node -> Service mapping.
    saas cluster create --name "$CLUSTER_D" --workers 0 --no-loadbalancer \
        -p 18080:30080 --yes >/dev/null 2>&1 \
        && pass "create ${CLUSTER_D} with --port-map 18080:30080" \
        || { fail "create ${CLUSTER_D} with --port-map 18080:30080"; return 1; }

    local ctx="kind-${CLUSTER_D}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/nodeport-test.yaml" >/dev/null \
        && pass "NodePort manifest applied on ${CLUSTER_D}" \
        || { fail "apply NodePort manifest on ${CLUSTER_D}"; return 1; }

    kubectl --context "$ctx" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1

    # The Deployment being "Available" doesn't guarantee kube-proxy has already programmed the
    # NodePort's iptables rules - confirmed in practice: a single curl right after "Available" can
    # fail on that race even though everything works correctly a few seconds later (confirmed by
    # hand: the same curl, repeated, responds immediately). Retried instead of accepting the first
    # failure as final.
    local tries=0 body=""
    while [ "$tries" -lt 15 ]; do
        body="$(curl -s -m 5 "http://localhost:18080" 2>/dev/null)"
        printf '%s' "$body" | grep -qi "nginx" && break
        sleep 2
        tries=$((tries + 1))
    done

    if printf '%s' "$body" | grep -qi "nginx"; then
        pass "curl to localhost:18080 reaches the pod through --port-map (nginx)"
    else
        fail "curl to localhost:18080 reaches the pod through --port-map"
    fi

    saas cluster delete "$CLUSTER_D" --yes >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_D}" || fail "deletion of ${CLUSTER_D}"
}

phase_fault_injection() {
    should_run fault-injection || return 0
    echo ""
    echo "=== Phase: exit code fault-injection in 'create' (${CLUSTER_E}) ==="

    # 'helm' is swapped for a fake binary that always fails, only for this 'create' invocation
    # (PATH restored right after). 'command -v helm' (used by _saas_cluster_check_deps) still
    # finds it, so the cluster creation itself proceeds normally; only the real "helm install
    # csi-driver-nfs" call fails deterministically. This proves live that 'create' reflects, in its
    # exit code, a partial failure (MetalLB/NFS) that happens AFTER the cluster itself was already
    # created successfully.
    local fake_bin
    fake_bin="$(mktemp -d)"
    cat > "$fake_bin/helm" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$fake_bin/helm"

    local rc
    PATH="${fake_bin}:${PATH}" saas cluster create --name "$CLUSTER_E" --workers 0 \
        --no-loadbalancer --storage-mode nfs --yes >/dev/null 2>&1
    rc=$?
    rm -rf "$fake_bin"

    if [ "$rc" -ne 0 ]; then
        pass "'create' returns a non-zero exit code when NFS storage fails after creating the cluster"
    else
        fail "'create' returns a non-zero exit code when NFS storage fails after creating the cluster (got: 0)"
    fi

    # The cluster must still exist: the failure is only in the post-creation component (NFS), not
    # the cluster itself - "warn, don't revert".
    if kind get clusters -q 2>/dev/null | grep -qx "$CLUSTER_E"; then
        pass "cluster ${CLUSTER_E} exists despite the NFS storage failure (not rolled back by design)"
    else
        fail "cluster ${CLUSTER_E} exists despite the NFS storage failure"
    fi

    saas cluster delete "$CLUSTER_E" --yes --purge-storage >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_E}" || fail "deletion of ${CLUSTER_E}"
}

phase_ingress() {
    should_run ingress || return 0
    echo ""
    echo "=== Phase: --expose-mode ingress-nginx (${CLUSTER_F}) ==="

    # A minimal cluster (no workers, no LoadBalancer): this phase only tests the ingress-controller,
    # it doesn't interact with MetalLB/storage.
    saas cluster create --name "$CLUSTER_F" --workers 0 --no-loadbalancer \
        --expose-mode ingress-nginx --yes >/dev/null 2>&1 \
        && pass "create ${CLUSTER_F} with --expose-mode ingress-nginx" \
        || { fail "create ${CLUSTER_F} with --expose-mode ingress-nginx"; return 1; }

    local ctx="kind-${CLUSTER_F}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/ingress-test.yaml" >/dev/null \
        && pass "Ingress manifest applied on ${CLUSTER_F}" \
        || { fail "apply Ingress manifest on ${CLUSTER_F}"; return 1; }

    kubectl --context "$ctx" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1

    # Same as phase_port_map: the controller can take a few more seconds to register the Ingress
    # after the Deployment is Available; retried instead of accepting the first failure as final.
    local tries=0 body=""
    while [ "$tries" -lt 15 ]; do
        body="$(curl -s -m 5 -H "Host: test.local" http://localhost/ 2>/dev/null)"
        printf '%s' "$body" | grep -qi "nginx" && break
        sleep 2
        tries=$((tries + 1))
    done

    if printf '%s' "$body" | grep -qi "nginx"; then
        pass "curl to localhost:80 (Host: test.local) reaches the pod through the Ingress (nginx)"
    else
        fail "curl to localhost:80 (Host: test.local) reaches the pod through the Ingress"
    fi

    saas cluster delete "$CLUSTER_F" --yes >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_F}" || fail "deletion of ${CLUSTER_F}"
}

phase_gateway_api() {
    should_run gateway-api || return 0
    echo ""
    echo "=== Phase: --expose-mode gateway-api (${CLUSTER_G}) ==="

    saas cluster create --name "$CLUSTER_G" --workers 0 --no-loadbalancer \
        --expose-mode gateway-api --yes >/dev/null 2>&1 \
        && pass "create ${CLUSTER_G} with --expose-mode gateway-api" \
        || { fail "create ${CLUSTER_G} with --expose-mode gateway-api"; return 1; }

    local ctx="kind-${CLUSTER_G}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/gateway-test.yaml" >/dev/null \
        && pass "HTTPRoute manifest applied on ${CLUSTER_G}" \
        || { fail "apply HTTPRoute manifest on ${CLUSTER_G}"; return 1; }

    kubectl --context "$ctx" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1

    local tries=0 body=""
    while [ "$tries" -lt 15 ]; do
        body="$(curl -s -m 5 -H "Host: test.local" http://localhost/ 2>/dev/null)"
        printf '%s' "$body" | grep -qi "nginx" && break
        sleep 2
        tries=$((tries + 1))
    done

    if printf '%s' "$body" | grep -qi "nginx"; then
        pass "curl to localhost:80 (Host: test.local) reaches the pod through the HTTPRoute (nginx)"
    else
        fail "curl to localhost:80 (Host: test.local) reaches the pod through the HTTPRoute"
    fi

    saas cluster delete "$CLUSTER_G" --yes >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_G}" || fail "deletion of ${CLUSTER_G}"
}

phase_expose() {
    should_run expose || return 0
    echo ""
    echo "=== Phase: expose (${CLUSTER_H}) ==="

    saas cluster create --name "$CLUSTER_H" --workers 0 --yes >/dev/null 2>&1 \
        && pass "create ${CLUSTER_H}" || { fail "create ${CLUSTER_H}"; return 1; }

    local ctx="kind-${CLUSTER_H}"
    kubectl --context "$ctx" apply -f - < "${MANIFESTS_DIR}/expose-test.yaml" >/dev/null \
        && pass "expose-test manifest applied on ${CLUSTER_H}" \
        || { fail "apply expose-test manifest on ${CLUSTER_H}"; return 1; }
    kubectl --context "$ctx" wait --for=condition=available --timeout=60s deployment/web >/dev/null 2>&1

    # --- ClusterIP: real test of the proxy's route-to-the-Service-CIDR mechanism ---
    saas cluster expose add "$CLUSTER_H" --service web-clusterip --host-port 18081 >/dev/null \
        && pass "'expose add' (ClusterIP Service) creates the proxy" \
        || { fail "'expose add' (ClusterIP Service) creates the proxy"; return 1; }

    # Same as other phases: the proxy can take a few seconds to bring up socat / install iproute2 /
    # apply the route to the Service CIDR.
    local tries=0 body=""
    while [ "$tries" -lt 15 ]; do
        body="$(curl -s -m 5 http://localhost:18081 2>/dev/null)"
        printf '%s' "$body" | grep -qi "nginx" && break
        sleep 2
        tries=$((tries + 1))
    done
    if printf '%s' "$body" | grep -qi "nginx"; then
        pass "curl to localhost:18081 reaches the ClusterIP via 'expose' (route to the Service CIDR)"
    else
        fail "curl to localhost:18081 reaches the ClusterIP via 'expose'"
    fi

    # --- idempotency: same cluster+port+protocol should fail ---
    if saas cluster expose add "$CLUSTER_H" --service web-clusterip --host-port 18081 >/dev/null 2>&1; then
        fail "a repeated 'expose add' on the same port should fail"
    else
        pass "a repeated 'expose add' on the same port fails (idempotency)"
    fi

    # --- list ---
    if saas cluster expose list "$CLUSTER_H" 2>/dev/null | grep -q 18081; then
        pass "'expose list' shows the port 18081 publication"
    else
        fail "'expose list' shows the port 18081 publication"
    fi

    # --- LoadBalancer via --target (already trivially reachable, no route fix needed; a control
    #     case against the ClusterIP one above) ---
    local lb_ip
    lb_ip="$(kubectl --context "$ctx" get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    local lb_tries=0
    while [ -z "$lb_ip" ] && [ "$lb_tries" -lt 30 ]; do
        sleep 2
        lb_ip="$(kubectl --context "$ctx" get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
        lb_tries=$((lb_tries + 1))
    done

    if [ -n "$lb_ip" ]; then
        pass "EXTERNAL-IP assigned to web-lb on ${CLUSTER_H}: ${lb_ip}"
        saas cluster expose add "$CLUSTER_H" --target "${lb_ip}:80" --host-port 18082 >/dev/null \
            && pass "'expose add --target' (LoadBalancer IP) creates the proxy" \
            || fail "'expose add --target' (LoadBalancer IP) creates the proxy"

        # The proxy takes a few seconds to start (installs iproute2 on the fly, applies the route,
        # brings up socat - same as the ClusterIP case above); a single curl right after
        # "docker run -d" can catch it mid-startup.
        local tries2=0 body2=""
        while [ "$tries2" -lt 15 ]; do
            body2="$(curl -s -m 5 http://localhost:18082 2>/dev/null)"
            printf '%s' "$body2" | grep -qi "nginx" && break
            sleep 2
            tries2=$((tries2 + 1))
        done
        if printf '%s' "$body2" | grep -qi "nginx"; then
            pass "curl to localhost:18082 reaches the LoadBalancer via 'expose --target'"
        else
            fail "curl to localhost:18082 reaches the LoadBalancer via 'expose --target'"
        fi
    else
        fail "EXTERNAL-IP assigned to web-lb on ${CLUSTER_H} (needed to test --target)"
    fi

    # --- removing one specific publication ---
    saas cluster expose remove "$CLUSTER_H" --host-port 18081 >/dev/null \
        && pass "'expose remove --host-port 18081' withdraws the proxy" \
        || fail "'expose remove --host-port 18081' withdraws the proxy"
    if curl -s -m 3 http://localhost:18081 >/dev/null 2>&1; then
        fail "localhost:18081 stops responding after 'expose remove'"
    else
        pass "localhost:18081 stops responding after 'expose remove'"
    fi

    # --- automatic cleanup on delete ---
    saas cluster delete "$CLUSTER_H" --yes >/dev/null 2>&1 \
        && pass "deletion of ${CLUSTER_H}" || fail "deletion of ${CLUSTER_H}"
    if [ -z "$(docker ps -aq --filter "label=kind-cluster.expose.cluster=${CLUSTER_H}" 2>/dev/null)" ]; then
        pass "'delete' automatically withdraws the remaining 'expose' proxies"
    else
        fail "'delete' automatically withdraws the remaining 'expose' proxies"
    fi
}

echo "🚀 Running saas cluster's tests"

phase_multi_cluster
phase_lb
phase_storage_local_path
phase_storage_nfs
phase_idempotency
phase_port_map
phase_fault_injection
phase_ingress
phase_gateway_api
phase_expose

echo ""
echo "=== Summary ==="
fail_count=0
for r in "${RESULTS[@]}"; do
    echo "$r"
    [[ "$r" == FAIL* ]] && fail_count=$((fail_count + 1))
done

echo ""
if [ "$fail_count" -eq 0 ]; then
    echo "✅ All steps PASS."
    exit 0
else
    echo "❌ ${fail_count} step(s) FAIL."
    exit 1
fi
