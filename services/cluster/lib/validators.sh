# --- Closed-domain validators for 'saas cluster', reused both for values that arrive via flag (direct validation) and via prompt (_saas_prompt_validated, lib/common.sh).

_saas_cluster_valid_workers()      { [[ "$1" =~ ^[0-9]+$ ]]; }
_saas_cluster_valid_storage_mode() { [[ "$1" == "local-path" || "$1" == "nfs" ]]; }
_saas_cluster_valid_expose_mode()  { [[ "$1" == "none" || "$1" == "ingress-nginx" || "$1" == "gateway-api" ]]; }
_saas_cluster_valid_storage_dir()  { [ -n "$1" ]; }
_saas_cluster_valid_port_map()     { [[ "$1" =~ ^[0-9]+:[0-9]+(/tcp|/udp)?$ ]]; }
_saas_cluster_valid_lb_range()     { [ -z "$1" ] || [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}-[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
_saas_cluster_valid_hostport()     { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_saas_cluster_valid_protocol()     { [[ "$1" == "tcp" || "$1" == "udp" ]]; }
_saas_cluster_valid_target()       { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]]; }
_saas_cluster_valid_service_ref()  { [[ "$1" =~ ^([a-zA-Z0-9._-]+/)?[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]; }

# _saas_cluster_valid_provider
# Only 'kind' is implemented today. This is the reserved extension point for
# a future remote/non-kind provider: adding one means accepting its name
# here and branching its own flags inside 'create', without renaming or
# restructuring 'create'/'delete'/'list'/'status'/'use' themselves (see
# CLAUDE.md's Design notes for services/cluster/).
_saas_cluster_valid_provider()     { [[ "$1" == "kind" ]]; }

_saas_cluster_ip_to_int() {
    local IFS=.
    local -a o=($1)
    echo "$(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))"
}

_saas_cluster_int_to_ip() {
    local i="$1"
    echo "$(( (i >> 24) & 255 )).$(( (i >> 16) & 255 )).$(( (i >> 8) & 255 )).$(( i & 255 ))"
}
