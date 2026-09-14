# --- SSH de GitLab expuesto desde un cluster kind sin tocar el puerto 22 real del host: reutiliza 'kind_cluster expose add' (proxy socat en un contenedor Docker aparte, mecanismo ya existente en bash-aliases) para mapear el puerto 22 del Service gitlab-shell a un puerto alto del host (por defecto 2222).

# _saas_gitlab_ssh_expose KIND_NAME NAMESPACE RELEASE HOST_PORT
_saas_gitlab_ssh_expose() {
    local kind_name="$1" ns="$2" release="$3" host_port="$4"
    _saas_require_kind_cluster_fn || return 1

    local svc="${release}-gitlab-shell"
    local ip
    ip="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    [ -n "$ip" ] || { _saas_log_err "Could not find the Service '$svc' in namespace '$ns'."; return 1; }

    kind_cluster expose remove "$kind_name" --host-port "$host_port" --protocol tcp >/dev/null 2>&1

    kind_cluster expose add "$kind_name" --target "${ip}:22" --host-port "$host_port" --protocol tcp
}

_saas_gitlab_ssh_config_help() {
    cat <<'EOF'
Usage: saas gitlab ssh-config [RELEASE] [OPTIONS]

Prints the ~/.ssh/config block needed to clone/pull/push over SSH
against RELEASE's GitLab without touching this PC's real port 22 (uses
the host port mapped with --ssh-host-port at install time, 2222 by
default).

Options:
      --apply   Add the block to ~/.ssh/config if not already present
                (doesn't touch the file if a 'Host DOMAIN' block is
                already there)
  -h, --help    Show this help

Examples:
  saas gitlab ssh-config
  saas gitlab ssh-config demo --apply
EOF
}

_saas_gitlab_ssh_config() {
    local release="" apply=false
    local args
    args=$(getopt -o h -l apply,help --name saas_gitlab_ssh_config -- "$@") || { _saas_gitlab_ssh_config_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --apply) apply=true; shift ;;
            -h|--help) _saas_gitlab_ssh_config_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
    [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "ssh-config only applies to installs with --cluster-mode kind."; return 1; }

    local block
    block="$(cat <<EOF
Host ${SAAS_GITLAB_STATE_DOMAIN}
    HostName 127.0.0.1
    Port ${SAAS_GITLAB_STATE_SSH_HOST_PORT}
    User git
EOF
)"
    echo "$block"

    if $apply; then
        local ssh_config="$HOME/.ssh/config"
        mkdir -p "$HOME/.ssh"
        if [ -f "$ssh_config" ] && grep -qx "Host ${SAAS_GITLAB_STATE_DOMAIN}" "$ssh_config"; then
            _saas_log_info "There's already a 'Host ${SAAS_GITLAB_STATE_DOMAIN}' block in $ssh_config, leaving it alone."
        else
            { echo ""; echo "$block"; } >> "$ssh_config"
            chmod 600 "$ssh_config"
            _saas_log_ok "Added to $ssh_config."
        fi
    fi
}
