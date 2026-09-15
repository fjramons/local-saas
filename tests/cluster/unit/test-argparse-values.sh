#!/usr/bin/env bash
# Fast unit tests (<1s, no real cluster) for saas cluster: validators (including --provider), IP
# arithmetic, --expose-mode reserved port-map rendering, and _saas_cluster_suggest_target's
# fallback logic (single cluster / active context / most-recently-created). Mocks
# kind/docker/kubectl by shadowing functions, same pattern as tests/gitlab/unit/test-argparse-values.sh
# and the sibling bash-aliases repo's own tests/kind-cluster/test-suggest-target.sh. Does not
# replace the real E2E suite (tests/cluster/e2e/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
declare -a RESULTS=()

pass() { RESULTS+=("PASS: $1"); echo "✅ PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); echo "❌ FAIL: $1"; }

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/services/cluster/cluster.sh"

# ------------------------------------------------------------------
# Validators
# ------------------------------------------------------------------

_saas_cluster_valid_workers 0 && pass "valid_workers accepts 0" || fail "valid_workers accepts 0"
_saas_cluster_valid_workers 3 && pass "valid_workers accepts 3" || fail "valid_workers accepts 3"
_saas_cluster_valid_workers -1 && fail "valid_workers rejects -1" || pass "valid_workers rejects -1"
_saas_cluster_valid_workers abc && fail "valid_workers rejects non-numeric" || pass "valid_workers rejects non-numeric"

_saas_cluster_valid_storage_mode local-path && pass "valid_storage_mode accepts local-path" || fail "valid_storage_mode accepts local-path"
_saas_cluster_valid_storage_mode nfs && pass "valid_storage_mode accepts nfs" || fail "valid_storage_mode accepts nfs"
_saas_cluster_valid_storage_mode ceph && fail "valid_storage_mode rejects ceph" || pass "valid_storage_mode rejects ceph"

_saas_cluster_valid_expose_mode none && pass "valid_expose_mode accepts none" || fail "valid_expose_mode accepts none"
_saas_cluster_valid_expose_mode ingress-nginx && pass "valid_expose_mode accepts ingress-nginx" || fail "valid_expose_mode accepts ingress-nginx"
_saas_cluster_valid_expose_mode gateway-api && pass "valid_expose_mode accepts gateway-api" || fail "valid_expose_mode accepts gateway-api"
_saas_cluster_valid_expose_mode traefik && fail "valid_expose_mode rejects traefik" || pass "valid_expose_mode rejects traefik"

_saas_cluster_valid_port_map "8080:80" && pass "valid_port_map accepts HOSTPORT:CONTAINERPORT" || fail "valid_port_map accepts HOSTPORT:CONTAINERPORT"
_saas_cluster_valid_port_map "8080:80/udp" && pass "valid_port_map accepts .../udp" || fail "valid_port_map accepts .../udp"
_saas_cluster_valid_port_map "8080" && fail "valid_port_map rejects a bare port" || pass "valid_port_map rejects a bare port"

_saas_cluster_valid_lb_range "" && pass "valid_lb_range accepts empty (auto)" || fail "valid_lb_range accepts empty (auto)"
_saas_cluster_valid_lb_range "172.19.0.200-172.19.0.209" && pass "valid_lb_range accepts START-END" || fail "valid_lb_range accepts START-END"
_saas_cluster_valid_lb_range "not-a-range" && fail "valid_lb_range rejects garbage" || pass "valid_lb_range rejects garbage"

_saas_cluster_valid_hostport 1 && pass "valid_hostport accepts 1" || fail "valid_hostport accepts 1"
_saas_cluster_valid_hostport 65535 && pass "valid_hostport accepts 65535" || fail "valid_hostport accepts 65535"
_saas_cluster_valid_hostport 0 && fail "valid_hostport rejects 0" || pass "valid_hostport rejects 0"
_saas_cluster_valid_hostport 65536 && fail "valid_hostport rejects 65536" || pass "valid_hostport rejects 65536"

_saas_cluster_valid_protocol tcp && pass "valid_protocol accepts tcp" || fail "valid_protocol accepts tcp"
_saas_cluster_valid_protocol udp && pass "valid_protocol accepts udp" || fail "valid_protocol accepts udp"
_saas_cluster_valid_protocol sctp && fail "valid_protocol rejects sctp" || pass "valid_protocol rejects sctp"

_saas_cluster_valid_target "172.19.0.5:53" && pass "valid_target accepts IP:PORT" || fail "valid_target accepts IP:PORT"
_saas_cluster_valid_target "not-an-ip:53" && fail "valid_target rejects a hostname" || pass "valid_target rejects a hostname"

_saas_cluster_valid_service_ref "my-svc" && pass "valid_service_ref accepts NAME" || fail "valid_service_ref accepts NAME"
_saas_cluster_valid_service_ref "ns/my-svc:8080" && pass "valid_service_ref accepts NS/NAME:PORT" || fail "valid_service_ref accepts NS/NAME:PORT"
_saas_cluster_valid_service_ref "" && fail "valid_service_ref rejects empty" || pass "valid_service_ref rejects empty"

# --provider: today only 'kind' is implemented, reserved extension point for a future remote
# provider (see CLAUDE.md's Design notes for services/cluster/).
_saas_cluster_valid_provider kind && pass "valid_provider accepts 'kind'" || fail "valid_provider accepts 'kind'"
_saas_cluster_valid_provider remote-ssh && fail "valid_provider rejects a not-yet-implemented provider" \
    || pass "valid_provider rejects a not-yet-implemented provider (reserved for the future)"

out="$(_saas_cluster_create --provider bogus --yes 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "must be 'kind'" \
    && pass "create: --provider bogus is rejected fast, with a clear error, before touching kind/docker" \
    || fail "create: --provider bogus is rejected fast, with a clear error (rc=$rc out='$out')"

# ------------------------------------------------------------------
# IP arithmetic
# ------------------------------------------------------------------

[ "$(_saas_cluster_ip_to_int 172.19.0.200)" = "$(( (172 << 24) + (19 << 16) + (0 << 8) + 200 ))" ] \
    && pass "ip_to_int computes the right integer" || fail "ip_to_int computes the right integer"
[ "$(_saas_cluster_int_to_ip "$(_saas_cluster_ip_to_int 10.244.5.9)")" = "10.244.5.9" ] \
    && pass "int_to_ip is the inverse of ip_to_int" || fail "int_to_ip is the inverse of ip_to_int"

_saas_cluster_ip_in_subnet "172.19.0.5" "172.19.0.0/16" \
    && pass "ip_in_subnet: inside the subnet" || fail "ip_in_subnet: inside the subnet"
_saas_cluster_ip_in_subnet "10.0.0.5" "172.19.0.0/16" \
    && fail "ip_in_subnet: outside the subnet" || pass "ip_in_subnet: outside the subnet"

# ------------------------------------------------------------------
# Port-map rendering (--expose-mode reserved ports)
# ------------------------------------------------------------------

out="$(_saas_cluster_expose_port_maps ingress-nginx)"
[ "$out" = $'80:80\n443:443' ] && pass "expose_port_maps: ingress-nginx reserves hostPort 80/443" \
    || fail "expose_port_maps: ingress-nginx reserves hostPort 80/443 (got: $out)"
out="$(_saas_cluster_expose_port_maps gateway-api)"
[ "$out" = $'80:30080\n443:30443' ] && pass "expose_port_maps: gateway-api reserves fixed NodePort 30080/30443" \
    || fail "expose_port_maps: gateway-api reserves fixed NodePort 30080/30443 (got: $out)"
out="$(_saas_cluster_expose_port_maps none)"
[ -z "$out" ] && pass "expose_port_maps: none reserves nothing" || fail "expose_port_maps: none reserves nothing"

# ------------------------------------------------------------------
# _saas_cluster_suggest_target: no real clusters, kind/docker/kubectl shadowed
# ------------------------------------------------------------------

kind() { :; }
out="$(_saas_cluster_suggest_target 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] \
    && pass "suggest_target: no clusters -> fails cleanly (no suggestion)" \
    || fail "suggest_target: no clusters -> fails cleanly (rc=$rc out='$out')"
unset -f kind

kind() { [ "$1" = "get" ] && printf 'only-one\n'; }
out="$(_saas_cluster_suggest_target 2>/dev/null)"
[ "$out" = "only-one" ] && pass "suggest_target: a single existing cluster -> suggested directly" \
    || fail "suggest_target: a single existing cluster -> suggested directly (got: $out)"
unset -f kind

kind() { [ "$1 $2" = "get clusters" ] && printf 'a\nb\nc\n'; }
kubectl() { [ "$1" = "config" ] && printf 'kind-b'; }
docker() { :; }
out="$(_saas_cluster_suggest_target 2>/dev/null)"
[ "$out" = "b" ] && pass "suggest_target: several clusters, active context 'kind-b' -> suggests 'b'" \
    || fail "suggest_target: several clusters, active context 'kind-b' -> suggests 'b' (got: $out)"
unset -f kind kubectl docker

kind() { [ "$1 $2" = "get clusters" ] && printf 'a\nb\nc\n'; }
kubectl() { [ "$1" = "config" ] && printf 'docker-desktop'; }  # not a kind-* context
docker() {
    [ "$1" != "inspect" ] && return 0
    case "$4" in
        a-control-plane) echo "2024-01-01T00:00:00Z" ;;
        b-control-plane) echo "2024-06-01T00:00:00Z" ;;
        c-control-plane) echo "2024-03-01T00:00:00Z" ;;
    esac
}
out="$(_saas_cluster_suggest_target 2>/dev/null)"
[ "$out" = "b" ] && pass "suggest_target: several clusters, no matching active context -> falls back to the newest ('b')" \
    || fail "suggest_target: several clusters, no matching active context -> falls back to the newest (got: $out)"
unset -f kind kubectl docker

# ------------------------------------------------------------------
# _saas_cluster_expose_container_name: same 'kind-expose-*' naming the legacy kind_cluster
# function uses, deliberately, for interchangeability (see CLAUDE.md's Design notes).
# ------------------------------------------------------------------

[ "$(_saas_cluster_expose_container_name mycluster 2222 tcp)" = "kind-expose-mycluster-2222-tcp" ] \
    && pass "expose_container_name: same naming as the legacy kind_cluster proxy" \
    || fail "expose_container_name: same naming as the legacy kind_cluster proxy"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
total="${#RESULTS[@]}"
failed=0
for r in "${RESULTS[@]}"; do [[ "$r" == FAIL:* ]] && failed=$((failed + 1)); done
echo "Total: $total   Failed: $failed"
[ "$failed" -eq 0 ]
