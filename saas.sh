# --- saas: single entry point to install/manage self-hosted SaaS services on Kubernetes (GitLab, and others in the future: databases, etc.). Two-level dispatcher: `saas SERVICE SUBCOMMAND ...` dispatches to a private function `_saas_<service>`, which in turn dispatches to its own subcommands.
#
# Usage: source this file from your shell (e.g. from ~/.bash_aliases or ~/.bashrc):
#   source "/path/to/local-saas/saas.sh"
#
# All internal paths are resolved relative to this file (BASH_SOURCE), never hardcoded: the repo can be cloned to any path.

_saas_root_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

_SAAS_ROOT_DIR="$(_saas_root_dir)"

# shellcheck source=lib/common.sh
source "$_SAAS_ROOT_DIR/lib/common.sh"
# shellcheck source=services/gitlab/gitlab.sh
source "$_SAAS_ROOT_DIR/services/gitlab/gitlab.sh"
# shellcheck source=services/vault/vault.sh
source "$_SAAS_ROOT_DIR/services/vault/vault.sh"

_saas_help() {
    cat <<'EOF'
Usage: saas SERVICE SUBCOMMAND [OPTIONS]

Single entry point to install and manage self-hosted SaaS services on
Kubernetes.

Available services:
  gitlab    Self-hosted GitLab (official Helm chart), see 'saas gitlab --help'
  vault     Self-hosted OpenBao (alias: openbao), see 'saas vault --help'

Examples:
  saas gitlab install
  saas gitlab --help
  saas gitlab install --help
  saas vault install
  saas openbao install --help
EOF
}

saas() {
    local service="${1:-}"
    [ $# -gt 0 ] && shift

    case "$service" in
        gitlab)
            _saas_gitlab "$@"
            ;;
        vault|openbao)
            _saas_vault "$@"
            ;;
        ""|-h|--help|help)
            _saas_help
            ;;
        *)
            _saas_log_err "Unknown SaaS service: '$service'"
            _saas_help >&2
            return 1
            ;;
    esac
}
