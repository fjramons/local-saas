# --- Optional host-port exposure for 'saas postgres' (--expose/--host-port, kind mode only): a
# host psql client can't reach a kind cluster's ClusterIP Services directly, so this reuses the
# cluster backend's own 'expose add' (a socat proxy in a separate Docker container, see
# lib/common.sh's _saas_cluster_backend_expose_*) to map PostgreSQL's Service to a high host port.
# Off by default: PostgreSQL's primary consumers are other SaaS services running inside the cluster
# (most notably 'saas gitlab'), not a host client. Structurally close to
# services/gitlab/lib/ssh.sh's _saas_gitlab_ssh_expose, with one deliberate difference: it targets
# the Service's EXTERNAL (MetalLB-assigned) address, not its ClusterIP. Verified live why this
# matters here, a real bug the first version of this file had: a Service's ClusterIP is only
# reachable via each kind node's own iptables DNAT rules, invisible to the separate docker container
# 'expose add' runs to publish the host port (confirmed live: that proxy warns the ClusterIP
# "doesn't look like it belongs to the kind docker network's subnet", and a real connection attempt
# through it fails outright). backend.sh's _saas_postgres_dev_apply makes this Service
# 'type: LoadBalancer' whenever EXPOSE is true precisely so MetalLB (installed by 'saas cluster
# create' by default) assigns it a real address inside that same docker network's subnet, which the
# proxy container CAN reach directly; this function reads that assigned address from
# '.status.loadBalancer.ingress[0].ip', not '.spec.clusterIP'.

# _saas_postgres_expose KIND_NAME NAMESPACE RELEASE HOST_PORT
_saas_postgres_expose() {
    local kind_name="$1" ns="$2" release="$3" host_port="$4"

    local svc="${release}-postgresql"
    local ip attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        ip="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
        [ -n "$ip" ] && break
        sleep 2
    done
    [ -n "$ip" ] || { _saas_log_err "Service '$svc' in namespace '$ns' has no external (LoadBalancer) address yet; is MetalLB installed and healthy?"; return 1; }

    _saas_cluster_backend_expose_remove "$kind_name" --host-port "$host_port" --protocol tcp >/dev/null 2>&1

    _saas_cluster_backend_expose_add "$kind_name" --target "${ip}:5432" --host-port "$host_port" --protocol tcp
}
