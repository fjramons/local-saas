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
# shellcheck source=services/cluster/cluster.sh
source "$_SAAS_ROOT_DIR/services/cluster/cluster.sh"
# shellcheck source=services/gitlab/gitlab.sh
source "$_SAAS_ROOT_DIR/services/gitlab/gitlab.sh"
# shellcheck source=services/vault/vault.sh
source "$_SAAS_ROOT_DIR/services/vault/vault.sh"
# shellcheck source=services/minio/minio.sh
source "$_SAAS_ROOT_DIR/services/minio/minio.sh"
# shellcheck source=services/postgres/postgres.sh
source "$_SAAS_ROOT_DIR/services/postgres/postgres.sh"

_saas_help() {
    cat <<'EOF'
Usage: saas SERVICE SUBCOMMAND [OPTIONS]

Single entry point to install and manage self-hosted SaaS services on
Kubernetes.

Available services:
  cluster   Local Kubernetes clusters via kind (alias: k8s), see
            'saas cluster --help'
  gitlab    Self-hosted GitLab (official Helm chart), see 'saas gitlab --help'
  vault     Self-hosted OpenBao (alias: openbao), see 'saas vault --help'
  minio     Standalone S3-compatible object storage (alias: object-storage),
            see 'saas minio --help'
  postgres  Standalone PostgreSQL database (alias: postgresql), see
            'saas postgres --help'

Examples:
  saas cluster create
  saas cluster --help
  saas gitlab install
  saas gitlab --help
  saas gitlab install --help
  saas vault install
  saas openbao install --help
  saas minio install
  saas object-storage install --help
  saas postgres install
  saas postgresql install --help
EOF
}

saas() {
    local service="${1:-}"
    [ $# -gt 0 ] && shift

    case "$service" in
        cluster|k8s)
            _saas_cluster "$@"
            ;;
        gitlab)
            _saas_gitlab "$@"
            ;;
        vault|openbao)
            _saas_vault "$@"
            ;;
        minio|object-storage)
            _saas_minio "$@"
            ;;
        postgres|postgresql)
            _saas_postgres "$@"
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
