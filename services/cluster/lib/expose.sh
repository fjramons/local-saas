# --- Selective service exposure ('saas cluster expose add|list|remove'): publishes specific Services of an already existing cluster on the LAN via a one-container-per-port socat proxy.

# _saas_cluster_service_cidr NAME
# The cluster's Service CIDR, read from kube-apiserver's own static pod
# flag (the only reliable source: not a fixed value across clusters). If it
# can't be determined, warns and falls back to kind's own default - it
# doesn't abort, since 'expose' still works the same unless the cluster
# uses a non-standard --service-cidr ('create' doesn't expose that flag).
_saas_cluster_service_cidr() {
    local name="$1"
    local ctx="kind-${name}"
    local cidr
    cidr="$(kubectl --context "$ctx" -n kube-system get pod -l component=kube-apiserver \
        -o jsonpath='{.items[0].spec.containers[0].command[*]}' 2>/dev/null \
        | tr ' ' '\n' | grep '^--service-cluster-ip-range=' | cut -d= -f2)"
    if [ -z "$cidr" ]; then
        _saas_log_warn "Could not determine '${name}''s Service CIDR; using kind's own default (10.96.0.0/12)."
        cidr="10.96.0.0/12"
    fi
    printf '%s' "$cidr"
}

# _saas_cluster_resolve_service_target NAME NAMESPACE SVC [PORT]
# Resolves a Service (LoadBalancer, ClusterIP or NodePort, doesn't matter:
# always resolved against .spec.clusterIP, which all three have unless
# headless) to "IP:PORT". If PORT is omitted, auto-selects when the Service
# has a single port; with several, requires naming one (never silently
# picks the first).
_saas_cluster_resolve_service_target() {
    local name="$1" ns="$2" svc="$3" port="$4"
    local ctx="kind-${name}"

    local cluster_ip
    cluster_ip="$(kubectl --context "$ctx" -n "$ns" get svc "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    if [ -z "$cluster_ip" ]; then
        _saas_log_err "Service '${ns}/${svc}' doesn't exist in '${name}'."
        return 1
    fi
    if [ "$cluster_ip" = "None" ]; then
        _saas_log_err "'${ns}/${svc}' is a headless Service (no ClusterIP); it can't be exposed."
        return 1
    fi

    # jsonpath separates several ports with spaces and adds NO trailing
    # newline, whether there's one port or several - a "while read" here
    # would lose the only port of a single-port Service (the most common
    # case: read fails, not empty, on the last line with no trailing
    # newline, so the loop body never runs). Unquoted expansion is used on
    # purpose, to split on spaces into an array.
    local ports_str
    ports_str="$(kubectl --context "$ctx" -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)"
    local -a ports=($ports_str)
    local p

    if [ -n "$port" ]; then
        local found=false
        for p in "${ports[@]}"; do
            [ "$p" = "$port" ] && found=true && break
        done
        $found || { _saas_log_err "'${ns}/${svc}' has no port ${port} (available ports: ${ports[*]})."; return 1; }
    elif [ "${#ports[@]}" -eq 1 ]; then
        port="${ports[0]}"
    else
        _saas_log_err "'${ns}/${svc}' has several ports (${ports[*]}); name one with --service ${ns}/${svc}:PORT."
        return 1
    fi

    printf '%s:%s' "$cluster_ip" "$port"
}

# _saas_cluster_expose_container_name NAME HOSTPORT PROTOCOL
# Uses the same 'kind-expose-*' container name and 'kind-cluster.expose.*'
# docker label namespace the legacy 'kind_cluster expose' function already
# uses (deliberate: an 'expose' entry created by either tool stays visible
# and manageable from the other, see CLAUDE.md's Design notes).
_saas_cluster_expose_container_name() {
    printf 'kind-expose-%s-%s-%s' "$1" "$2" "$3"
}

# _saas_cluster_expose_add [NAME] (--service [NS/]SVC[:PORT] | --target IP:PORT) --host-port PORT [--protocol tcp|udp]
_saas_cluster_expose_add() {
    local service="" target="" hostport="" protocol="tcp" non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"

    local args
    args=$(getopt -o h -l service:,target:,host-port:,protocol:,non-interactive,help --name saas_cluster_expose_add -- "$@") || {
        _saas_cluster_expose_add_help; return 1
    }
    eval set -- "$args"

    while true; do
        case "$1" in
            --service)          service="$2"; shift 2 ;;
            --target)           target="$2"; shift 2 ;;
            --host-port)        hostport="$2"; shift 2 ;;
            --protocol)         protocol="$2"; shift 2 ;;
            --non-interactive)  non_interactive=true; shift ;;
            -h|--help)          _saas_cluster_expose_add_help; return 0 ;;
            --)                 shift; break ;;
        esac
    done

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    if [ -z "$service" ] && [ -z "$target" ]; then
        _saas_log_err "--service or --target is required."
        _saas_cluster_expose_add_help; return 1
    fi
    if [ -n "$service" ] && [ -n "$target" ]; then
        _saas_log_err "--service and --target are mutually exclusive."
        _saas_cluster_expose_add_help; return 1
    fi
    if [ -z "$hostport" ]; then
        _saas_log_err "--host-port is required."
        _saas_cluster_expose_add_help; return 1
    fi
    _saas_cluster_valid_hostport "$hostport" || { _saas_log_err "Invalid --host-port: '$hostport' (must be 1-65535)."; return 1; }
    _saas_cluster_valid_protocol "$protocol" || { _saas_log_err "Invalid --protocol: '$protocol' (tcp or udp)."; return 1; }

    local target_ip target_port
    if [ -n "$service" ]; then
        _saas_cluster_valid_service_ref "$service" || {
            _saas_log_err "Invalid --service: '$service' (format: [NS/]NAME[:PORT])."
            return 1
        }
        local ns rest svc port
        case "$service" in
            */*) ns="${service%%/*}"; rest="${service#*/}" ;;
            *)   ns="default"; rest="$service" ;;
        esac
        case "$rest" in
            *:*) svc="${rest%%:*}"; port="${rest#*:}" ;;
            *)   svc="$rest"; port="" ;;
        esac

        local resolved
        resolved="$(_saas_cluster_resolve_service_target "$name" "$ns" "$svc" "$port")" || return 1
        target_ip="${resolved%%:*}"
        target_port="${resolved#*:}"
    else
        _saas_cluster_valid_target "$target" || { _saas_log_err "Invalid --target: '$target' (format: IP:PORT)."; return 1; }
        target_ip="${target%%:*}"
        target_port="${target#*:}"

        local subnet
        subnet="$(_saas_cluster_docker_network_subnet)"
        if [ -z "$subnet" ]; then
            _saas_log_info "Could not check that --target is inside the 'kind' docker network (jq missing, or the network couldn't be inspected); continuing anyway."
        elif ! _saas_cluster_ip_in_subnet "$target_ip" "$subnet"; then
            _saas_log_warn "'${target_ip}' doesn't look like it belongs to the 'kind' docker network's subnet (${subnet}); the proxy may not be able to reach it."
        fi
    fi

    local container_name
    container_name="$(_saas_cluster_expose_container_name "$name" "$hostport" "$protocol")"

    if docker ps -aq --filter "label=kind-cluster.expose.cluster=${name}" \
                     --filter "label=kind-cluster.expose.hostport=${hostport}" \
                     --filter "label=kind-cluster.expose.protocol=${protocol}" \
                     2>/dev/null | grep -q .; then
        _saas_log_err "There's already an active publication on port ${hostport}/${protocol} of '${name}' (container '${container_name}'). Run 'saas cluster expose remove' first."
        return 1
    fi

    local cp_ip svc_cidr listen connect
    cp_ip="$(_saas_cluster_node_ip "$name")"
    if [ -z "$cp_ip" ]; then
        _saas_log_err "Could not determine '${name}''s control-plane node IP."
        return 1
    fi
    svc_cidr="$(_saas_cluster_service_cidr "$name")"

    if [ "$protocol" = "udp" ]; then
        listen="UDP-LISTEN"; connect="UDP"
    else
        listen="TCP-LISTEN"; connect="TCP"
    fi

    _saas_log_step "Publishing ${target_ip}:${target_port} on host port ${hostport}/${protocol}..."
    # The alpine/socat image doesn't bundle iproute2 ("ip"); it's installed
    # on the fly on every proxy startup (an uncached image, see "Pinned
    # versions" in CLAUDE.md). The route to the Service CIDR via the
    # control-plane is what makes a plain ClusterIP reachable from this
    # container (see CLAUDE.md's Design notes): without it, only node IPs,
    # MetalLB LoadBalancer IPs, and NodePorts would be reachable, all
    # already present in the 'kind' docker network's own L2 domain. This
    # route only affects this container's own private routing table, never
    # the real host or the cluster's nodes.
    # Explicit "-p 0.0.0.0:...", not just "-p HOSTPORT:...": confirmed live
    # that on a host with IPv6 enabled at the Docker daemon level (a "kind"
    # network with EnableIPv6), omitting the IP also publishes on
    # "[::]:HOSTPORT" - and since socat only listens on IPv4 inside the
    # container, that IPv6 publication has nothing behind it, so a client
    # whose "happy eyeballs" tries IPv6 first (e.g. "curl localhost" on
    # Linux, which usually resolves ::1 before 127.0.0.1) gets "Recv
    # failure: Connection reset" instead of a response. Pinning the IP to
    # 0.0.0.0 avoids that phantom IPv6 publish.
    docker run -d \
        --name "$container_name" \
        --network kind \
        --cap-add=NET_ADMIN \
        -p "0.0.0.0:${hostport}:${hostport}/${protocol}" \
        --label "kind-cluster.expose=true" \
        --label "kind-cluster.expose.cluster=${name}" \
        --label "kind-cluster.expose.hostport=${hostport}" \
        --label "kind-cluster.expose.protocol=${protocol}" \
        --label "kind-cluster.expose.target=${target_ip}:${target_port}" \
        --entrypoint sh \
        alpine/socat:1.8.1.3 \
        -c "apk add --no-cache iproute2 >/dev/null 2>&1; ip route replace ${svc_cidr} via ${cp_ip} 2>/dev/null; exec socat ${listen}:${hostport},fork,reuseaddr ${connect}:${target_ip}:${target_port}" \
        >/dev/null \
        || { _saas_log_err "Failed to create the proxy '${container_name}' (is host port ${hostport} already in use?)."; return 1; }

    _saas_log_ok "Published: 0.0.0.0:${hostport}/${protocol} -> ${target_ip}:${target_port}  (proxy: ${container_name})"
    _saas_log_info "Also reachable from other machines on the LAN (not just this host), firewall permitting."
}

_saas_cluster_expose_list() {
    local non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local args
    args=$(getopt -o h -l non-interactive,help --name saas_cluster_expose_list -- "$@") || {
        _saas_cluster_expose_list_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_cluster_expose_list_help; return 0 ;;
            --)                shift; break ;;
        esac
    done

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    local rows
    rows="$(docker ps --filter "label=kind-cluster.expose.cluster=${name}" \
        --format '{{.Label "kind-cluster.expose.hostport"}}	{{.Label "kind-cluster.expose.protocol"}}	{{.Label "kind-cluster.expose.target"}}	{{.Names}}' 2>/dev/null)"

    if [ -z "$rows" ]; then
        echo "No active 'expose' publications on '${name}'."
        return 0
    fi

    printf "%-12s %-10s %-24s %s\n" "HOST-PORT" "PROTOCOL" "TARGET" "CONTAINER"
    while IFS=$'\t' read -r hostport protocol target cname; do
        [ -z "$hostport" ] && continue
        printf "%-12s %-10s %-24s %s\n" "$hostport" "$protocol" "$target" "$cname"
    done <<< "$rows"
}

_saas_cluster_expose_remove() {
    local hostport="" protocol="tcp" all=false non_interactive="${SAAS_CLUSTER_NON_INTERACTIVE:-false}"
    local args
    args=$(getopt -o h -l host-port:,protocol:,all,non-interactive,help --name saas_cluster_expose_remove -- "$@") || {
        _saas_cluster_expose_remove_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --host-port)        hostport="$2"; shift 2 ;;
            --protocol)         protocol="$2"; shift 2 ;;
            --all)               all=true; shift ;;
            --non-interactive)  non_interactive=true; shift ;;
            -h|--help)          _saas_cluster_expose_remove_help; return 0 ;;
            --)                 shift; break ;;
        esac
    done

    local name="$1"
    if [ -z "$name" ]; then
        name="$(_saas_cluster_suggest_target)" || return 1
        name="$(_saas_prompt "Cluster" "$name" "$non_interactive")"
    fi

    if ! kind get clusters -q 2>/dev/null | grep -qx "$name"; then
        _saas_log_err "No kind cluster named '$name' exists."
        return 1
    fi

    if ! $all && [ -z "$hostport" ]; then
        _saas_log_err "--host-port or --all is required."
        _saas_cluster_expose_remove_help; return 1
    fi
    if $all && [ -n "$hostport" ]; then
        _saas_log_err "--host-port and --all are mutually exclusive."
        _saas_cluster_expose_remove_help; return 1
    fi
    if ! $all; then
        _saas_cluster_valid_hostport "$hostport" || { _saas_log_err "Invalid --host-port: '$hostport'."; return 1; }
    fi
    _saas_cluster_valid_protocol "$protocol" || { _saas_log_err "Invalid --protocol: '$protocol' (tcp or udp)."; return 1; }

    local -a filter=(--filter "label=kind-cluster.expose.cluster=${name}")
    $all || filter+=(--filter "label=kind-cluster.expose.hostport=${hostport}" --filter "label=kind-cluster.expose.protocol=${protocol}")

    local ids
    ids="$(docker ps -aq "${filter[@]}" 2>/dev/null)"
    if [ -z "$ids" ]; then
        if $all; then
            echo "No active 'expose' publications on '${name}'."
            return 0
        fi
        _saas_log_err "There's no publication on port ${hostport}/${protocol} of '${name}'."
        return 1
    fi

    printf '%s\n' "$ids" | xargs -r docker rm -f >/dev/null \
        && _saas_log_ok "Publication(s) removed." \
        || { _saas_log_err "Failed to remove one or more publications."; return 1; }
}

_saas_cluster_expose_help() {
    cat <<'EOF'
Usage: saas cluster expose SUBCOMMAND [OPTIONS]

Publishes specific services of an already existing kind cluster on the
host's network interfaces (also reachable from the LAN, not just from the
Docker host itself), without recreating the cluster. Mechanism: one
independent, ephemeral Docker container per exposed port, running 'socat'
as a pure L4 forwarder, connected to the 'kind' docker network and
published with 'docker run -p'.

Don't confuse this with 'create''s --expose-mode: that installs an
ingress-controller/Gateway API inside the cluster at creation time; this
publishes, after creation, any specific LoadBalancer/ClusterIP Service,
including the ingress-controller/Gateway API's own Service if one is
already installed.

Subcommands:
  add       Publish a Service or a specific IP:port on a host port
  list      List a cluster's active publications
  remove    Withdraw one or all of a cluster's publications

See 'saas cluster expose SUBCOMMAND --help' for each one's options.
EOF
}

_saas_cluster_expose_add_help() {
    cat <<'EOF'
Usage: saas cluster expose add [NAME] (--service [NS/]SVC[:PORT] | --target IP:PORT) --host-port PORT [OPTIONS]

Publishes a Service (or an arbitrary IP:port inside the 'kind' docker
network) on a host port, also reachable from the LAN. If NAME is omitted, a
default cluster is suggested the same way as
'delete'/'status'/'use'/'deploy-loadbalancer'.

Unlike every other option in this command, --service/--target and
--host-port are required: they have no reasonable default, so omitting
them shows this help and fails, instead of being prompted for.

Options:
      --service [NS/]SVC[:PORT]  Service to publish (namespace defaults to
                              default). If the Service has a single port,
                              it doesn't need to be given; with several,
                              name one with ':PORT'. Works the same with
                              LoadBalancer, ClusterIP, or NodePort
                              Services, including ingress-nginx/Envoy
                              Gateway's own Service if already installed.
                              Mutually exclusive with --target.
      --target IP:PORT         Exact IP:port inside the 'kind' docker
                              network (e.g. a node's IP, or a MetalLB
                              LoadBalancer IP), instead of resolving a
                              Service. Mutually exclusive with --service.
      --host-port PORT          Host port to publish on (required)
      --protocol tcp|udp         Protocol (default: tcp)
      --non-interactive          Don't prompt for the cluster name if omitted
  -h, --help                      Show this help

Examples:
  saas cluster expose add my-cluster --service my-service --host-port 8080
  saas cluster expose add my-cluster --service ns-app/api:9090 --host-port 9090
  saas cluster expose add my-cluster --target 172.19.0.5:53 --host-port 5353 --protocol udp
EOF
}

_saas_cluster_expose_list_help() {
    cat <<'EOF'
Usage: saas cluster expose list [NAME]

Lists a cluster's active 'expose' publications (host port, protocol,
target, container). If NAME is omitted, a default cluster is suggested the
same way as 'delete'/'status'/'use'.

Options:
      --non-interactive   Don't prompt for the name; use the suggested one
  -h, --help               Show this help

Examples:
  saas cluster expose list
  saas cluster expose list my-cluster
EOF
}

_saas_cluster_expose_remove_help() {
    cat <<'EOF'
Usage: saas cluster expose remove [NAME] (--host-port PORT [--protocol tcp|udp] | --all)

Withdraws one specific 'expose' publication, or all of a cluster's with
--all. If NAME is omitted, a default cluster is suggested the same way as
'delete'/'status'/'use'. No confirmation is asked: these are pure
infrastructure containers with no user data (unlike 'delete
--purge-storage').

Options:
      --host-port PORT    Host port of the publication to withdraw
      --protocol tcp|udp    Protocol (default: tcp)
      --all                  Withdraw all of the cluster's publications
      --non-interactive      Don't prompt for the name; use the suggested one
  -h, --help                  Show this help

Examples:
  saas cluster expose remove my-cluster --host-port 8080
  saas cluster expose remove my-cluster --all
EOF
}

# _saas_cluster_expose SUBCOMMAND [OPTIONS]
_saas_cluster_expose() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift

    case "$sub" in
        add)                _saas_cluster_expose_add "$@" ;;
        list)               _saas_cluster_expose_list "$@" ;;
        remove)             _saas_cluster_expose_remove "$@" ;;
        ""|-h|--help|help)  _saas_cluster_expose_help ;;
        *)
            _saas_log_err "Unknown subcommand: 'expose ${sub}'"
            _saas_cluster_expose_help >&2
            return 1
            ;;
    esac
}
