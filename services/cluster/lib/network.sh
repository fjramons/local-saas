# --- Docker-network-level helpers for 'saas cluster': IP/subnet checks, the 'kind' docker network's own subnet, and a node's IP inside it.

# _saas_cluster_ip_in_subnet IP SUBNET_CIDR
# IPv4 CIDR membership check, used only as an advisory (non-blocking)
# sanity check by 'saas cluster expose add --target'.
_saas_cluster_ip_in_subnet() {
    local ip="$1" subnet="$2"
    local base="${subnet%%/*}" prefix="${subnet##*/}"
    local ip_i base_i mask
    ip_i=$(_saas_cluster_ip_to_int "$ip")
    base_i=$(_saas_cluster_ip_to_int "$base")
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( ip_i & mask )) -eq $(( base_i & mask )) ]
}

# _saas_cluster_docker_network_subnet
# IPv4 subnet of the 'kind' docker network. It can have dual-stack IPAM
# (IPv4 + IPv6); the IPv4 entry is picked explicitly (no ':' in the CIDR),
# never assuming .Config[0] is it. Used both by the MetalLB pool
# calculation and by 'expose add --target''s sanity check.
_saas_cluster_docker_network_subnet() {
    docker network inspect kind 2>/dev/null | jq -r '[.[0].IPAM.Config[]? | select(.Subnet != null and (.Subnet | contains(":") | not))][0].Subnet // empty'
}

# _saas_cluster_node_ip NAME [SUFFIX=control-plane]
# IP of the node (control-plane by default) on the 'kind' docker network.
_saas_cluster_node_ip() {
    local name="$1" suffix="${2:-control-plane}"
    docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${name}-${suffix}" 2>/dev/null
}
