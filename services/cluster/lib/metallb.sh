# --- LoadBalancer (MetalLB) install and IP-pool collision avoidance for 'saas cluster'.

# _saas_cluster_all_pool_ranges EXCLUDE_NAME
# Prints, one per line, the MetalLB IPAddressPool addresses of every other
# existing kind cluster (to avoid collisions). This inspects the 'kind'
# docker network and each cluster's own live MetalLB state directly, so it
# stays correct regardless of whether a sibling cluster was created by
# 'saas cluster' or by the legacy 'kind_cluster' function.
_saas_cluster_all_pool_ranges() {
    local exclude="$1"
    local clusters c addrs a
    clusters="$(kind get clusters -q 2>/dev/null)"
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        [ "$c" = "$exclude" ] && continue
        # --request-timeout bounds this call: without it, an existing kind
        # cluster whose context has become unreachable (stopped containers,
        # broken network) can hang the creation of a brand new cluster with
        # no visible message, since this runs before
        # _saas_cluster_install_metallb prints anything about the IP pool.
        addrs="$(kubectl --context "kind-${c}" --request-timeout=5s -n metallb-system get ipaddresspools.metallb.io -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null)"
        for a in $addrs; do
            echo "$a"
        done
    done <<< "$clusters"
}

# _saas_cluster_lb_pool_range NAME [EXPLICIT_RANGE]
# Calculates (or validates, if EXPLICIT_RANGE is given) an IP range for the
# cluster's MetalLB pool, avoiding overlaps with other kind clusters that
# share the 'kind' docker network.
_saas_cluster_lb_pool_range() {
    local name="$1" explicit="$2"
    local pool_size="${SAAS_CLUSTER_LB_POOL_SIZE:-10}"

    local subnet
    subnet="$(_saas_cluster_docker_network_subnet)"
    if [ -z "$subnet" ]; then
        _saas_log_err "Could not determine the 'kind' docker network's subnet."
        return 1
    fi

    local base_ip="${subnet%%/*}" prefix_len="${subnet##*/}"
    local base_int; base_int=$(_saas_cluster_ip_to_int "$base_ip")
    local host_bits=$(( 32 - prefix_len ))
    local host_count=$(( 1 << host_bits ))
    local reserve_offset=100
    local max_slots=$(( (host_count - reserve_offset) / pool_size ))
    [ "$max_slots" -lt 1 ] && max_slots=1
    # No artificial upper bound: the loop below (_saas_cluster_range_free)
    # only does arithmetic and compares against already-precomputed lists
    # (assigned_ips, existing_ranges), with no Docker/kubectl calls inside
    # the loop, so iterating over the natural max number of slots has no
    # meaningful cost even with large subnets. Capping it (as a fixed 200
    # used to) only shrank the search space for no benefit and increased
    # collisions when many kind clusters run at once.

    local assigned_ips existing_ranges
    assigned_ips="$(docker network inspect kind 2>/dev/null | jq -r '.[0].Containers[]?.IPv4Address // empty' | cut -d/ -f1)"
    existing_ranges="$(_saas_cluster_all_pool_ranges "$name")"

    _saas_cluster_range_free() {
        local s="$1" e="$2" ip ip_i r rs re
        for ip in $assigned_ips; do
            [ -z "$ip" ] && continue
            ip_i=$(_saas_cluster_ip_to_int "$ip")
            [ "$ip_i" -ge "$s" ] && [ "$ip_i" -le "$e" ] && return 1
        done
        while IFS= read -r r; do
            [ -z "$r" ] && continue
            rs=$(_saas_cluster_ip_to_int "${r%-*}"); re=$(_saas_cluster_ip_to_int "${r#*-}")
            [ "$s" -le "$re" ] && [ "$e" -ge "$rs" ] && return 1
        done <<< "$existing_ranges"
        return 0
    }

    if [ -n "$explicit" ]; then
        local s e
        s=$(_saas_cluster_ip_to_int "${explicit%-*}"); e=$(_saas_cluster_ip_to_int "${explicit#*-}")
        _saas_cluster_range_free "$s" "$e" \
            || _saas_log_warn "The range '${explicit}' might overlap with another kind cluster."
        echo "$explicit"
        return 0
    fi

    local hash slot start_int end_int tries=0
    hash="$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
    slot=$(( hash % max_slots ))

    while [ "$tries" -lt "$max_slots" ]; do
        start_int=$(( base_int + reserve_offset + slot * pool_size ))
        end_int=$(( start_int + pool_size - 1 ))
        if _saas_cluster_range_free "$start_int" "$end_int"; then
            echo "$(_saas_cluster_int_to_ip "$start_int")-$(_saas_cluster_int_to_ip "$end_int")"
            return 0
        fi
        slot=$(( (slot + 1) % max_slots ))
        tries=$(( tries + 1 ))
    done

    _saas_log_err "Could not find a free IP range for MetalLB. Use --lb-range to specify one manually."
    return 1
}

_saas_cluster_render_metallb_pool() {
    local name="$1" range="$2"
    local start="${range%-*}" end="${range#*-}"

    DEV_ENV_CLUSTER_NAME="$name" LB_RANGE_START="$start" LB_RANGE_END="$end" \
        envsubst '${DEV_ENV_CLUSTER_NAME} ${LB_RANGE_START} ${LB_RANGE_END}' <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${DEV_ENV_CLUSTER_NAME}-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LB_RANGE_START}-${LB_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${DEV_ENV_CLUSTER_NAME}-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - ${DEV_ENV_CLUSTER_NAME}-pool
EOF
}

# _saas_cluster_install_metallb NAME [EXPLICIT_RANGE]
_saas_cluster_install_metallb() {
    local name="$1" explicit_range="$2"
    local ctx="kind-${name}"

    _saas_log_step "Installing MetalLB on '${name}' via Helm..."
    timeout 30 helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1
    timeout 30 helm repo update metallb >/dev/null 2>&1
    helm install metallb metallb/metallb \
        --kube-context "$ctx" \
        -n metallb-system --create-namespace --timeout 180s \
        || { _saas_log_err "Failed to install MetalLB."; return 1; }

    # No --wait on the helm install: MetalLB's chart includes extra
    # components (e.g. frr-k8s) unrelated to the L2 mode used here, and
    # they can take a while to become Ready or simply aren't needed.
    # controller/speaker are waited on explicitly instead. With Helm
    # (release "metallb") the names carry the release prefix:
    # "metallb-controller" / "metallb-speaker", not "controller"/"speaker"
    # as in the plain, no-Helm manifest.
    #
    # "kubectl wait" prints nothing while waiting (unlike "rollout status",
    # which shows incremental progress): measured in practice, this leaves
    # ~30s of total silence after "helm install"'s own output in the
    # common case, and up to 180s in the worst case - without the explicit
    # message below it looks like a hang.
    _saas_log_wait "Waiting for MetalLB's controller to become available (can take up to 3 min)..."
    kubectl --context "$ctx" -n metallb-system wait --for=condition=Available --timeout=180s deployment/metallb-controller \
        || { _saas_log_err "MetalLB's controller never became available."; return 1; }
    kubectl --context "$ctx" -n metallb-system rollout status --timeout=180s daemonset/metallb-speaker \
        || { _saas_log_err "MetalLB's speaker never became available."; return 1; }

    _saas_log_step "Checking other kind clusters' IP ranges to avoid collisions..."
    local range
    range="$(_saas_cluster_lb_pool_range "$name" "$explicit_range")" || return 1

    _saas_log_step "Configuring MetalLB's IP pool: ${range}"
    # MetalLB's validating webhook takes a few seconds to become reachable
    # even after the controller reports Available (a known race); retried
    # before giving up.
    local pool_yaml attempt=0
    pool_yaml="$(_saas_cluster_render_metallb_pool "$name" "$range")"
    until printf '%s\n' "$pool_yaml" | kubectl --context "$ctx" apply -f - >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -eq 1 ]; then
            _saas_log_wait "MetalLB's webhook isn't responding yet, retrying every 3s (up to 30s)..."
        fi
        if [ "$attempt" -ge 10 ]; then
            _saas_log_err "Failed to apply the IPAddressPool (MetalLB's webhook didn't respond in time)."
            return 1
        fi
        sleep 3
    done

    _saas_log_ok "MetalLB ready. IP range: ${range}"
}
