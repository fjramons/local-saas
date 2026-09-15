# --- kind Cluster config YAML rendering for 'saas cluster create'.

# _saas_cluster_expose_port_maps EXPOSE_MODE
# Prints, one per line (HOSTPORT:CONTAINERPORT format), the port mappings
# reserved by --expose-mode. ingress-nginx uses a direct hostPort (80/443
# as-is, like kind's own official manifest); gateway-api uses a fixed
# NodePort (30080/30443), the same mechanism --port-map already exercises.
_saas_cluster_expose_port_maps() {
    case "$1" in
        ingress-nginx) printf '80:80\n443:443\n' ;;
        gateway-api)   printf '80:30080\n443:30443\n' ;;
    esac
}

# _saas_cluster_render_node_extras ROLE STORAGE_MODE STORAGE_FIX LOCAL_PATH_DIR NFS_EXPORTS_DIR EXPOSE_MODE [PORT_MAP...]
_saas_cluster_render_node_extras() {
    local role="$1" storage_mode="$2" storage_fix="$3" local_path_dir="$4" nfs_exports_dir="$5" expose_mode="$6"
    shift 6
    local -a port_maps=("$@")

    local -a mounts=()
    if [ "$storage_mode" = "local-path" ] && $storage_fix; then
        mounts+=("${local_path_dir}|/var/local-path-provisioner")
    fi
    if [ "$storage_mode" = "nfs" ] && [ "$role" = "control-plane" ]; then
        mounts+=("${nfs_exports_dir}|/mnt/nfs-exports")
    fi

    if [ "${#mounts[@]}" -gt 0 ]; then
        echo "    extraMounts:"
        local m h c
        for m in "${mounts[@]}"; do
            h="${m%%|*}"; c="${m##*|}"
            echo "      - hostPath: ${h}"
            echo "        containerPath: ${c}"
        done
    fi

    # The ingress-ready=true label is only needed on the control-plane (the
    # only node with the host's 80/443 ports mapped); both the
    # ingress-nginx chart's nodeSelector and Gateway API's EnvoyProxy one
    # reuse it.
    if [ "$role" = "control-plane" ] && [ "$expose_mode" != "none" ]; then
        echo "    kubeadmConfigPatches:"
        echo "      - |"
        echo "        kind: InitConfiguration"
        echo "        nodeRegistration:"
        echo "          kubeletExtraArgs:"
        echo "            node-labels: \"ingress-ready=true\""
    fi

    local -a all_port_maps=("${port_maps[@]}")
    if [ "$role" = "control-plane" ] && [ "$expose_mode" != "none" ]; then
        local expose_pm
        while IFS= read -r expose_pm; do
            [ -z "$expose_pm" ] && continue
            all_port_maps+=("$expose_pm")
        done < <(_saas_cluster_expose_port_maps "$expose_mode")
    fi

    if [ "$role" = "control-plane" ] && [ "${#all_port_maps[@]}" -gt 0 ]; then
        echo "    extraPortMappings:"
        local pm host_port container_port protocol
        for pm in "${all_port_maps[@]}"; do
            protocol="TCP"
            case "$pm" in
                */udp) protocol="UDP"; pm="${pm%/udp}" ;;
                */tcp) protocol="TCP"; pm="${pm%/tcp}" ;;
            esac
            host_port="${pm%%:*}"
            container_port="${pm##*:}"
            echo "      - containerPort: ${container_port}"
            echo "        hostPort: ${host_port}"
            echo "        protocol: ${protocol}"
        done
    fi
}

# _saas_cluster_render_kind_config NAME WORKERS STORAGE_MODE STORAGE_FIX STORAGE_DIR EXPOSE_MODE [PORT_MAP...]
_saas_cluster_render_kind_config() {
    local name="$1" workers="$2" storage_mode="$3" storage_fix="$4" storage_dir="$5" expose_mode="$6"
    shift 6
    local -a port_maps=("$@")

    local local_path_dir="${storage_dir}/${name}/local-path-provisioner"
    local nfs_exports_dir="${storage_dir}/${name}/nfs-exports"

    if [ "$storage_mode" = "local-path" ] && $storage_fix; then
        mkdir -p "$local_path_dir" || { _saas_log_err "Could not create '$local_path_dir'."; return 1; }
    fi
    if [ "$storage_mode" = "nfs" ]; then
        mkdir -p "$nfs_exports_dir" || { _saas_log_err "Could not create '$nfs_exports_dir'."; return 1; }
    fi

    echo "kind: Cluster"
    echo "apiVersion: kind.x-k8s.io/v1alpha4"
    echo "nodes:"
    echo "  - role: control-plane"
    _saas_cluster_render_node_extras control-plane "$storage_mode" "$storage_fix" "$local_path_dir" "$nfs_exports_dir" "$expose_mode" "${port_maps[@]}"

    local i
    for ((i = 0; i < workers; i++)); do
        echo "  - role: worker"
        _saas_cluster_render_node_extras worker "$storage_mode" "$storage_fix" "$local_path_dir" "$nfs_exports_dir" "$expose_mode"
    done
}
