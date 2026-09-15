# --- saas postgres: standalone PostgreSQL on Kubernetes (subcommand dispatcher). All paths are
# resolved relative to this file (BASH_SOURCE), never hardcoded. Also reachable as 'saas
# postgresql' (see saas.sh): both spellings dispatch here identically, same convention as
# 'vault'/'openbao' and 'minio'/'object-storage'.

_SAAS_POSTGRES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=lib/state.sh
source "$_SAAS_POSTGRES_DIR/lib/state.sh"
# shellcheck source=lib/cluster.sh
source "$_SAAS_POSTGRES_DIR/lib/cluster.sh"
# shellcheck source=lib/expose.sh
source "$_SAAS_POSTGRES_DIR/lib/expose.sh"
# shellcheck source=lib/tls.sh
source "$_SAAS_POSTGRES_DIR/lib/tls.sh"
# shellcheck source=lib/backend.sh
source "$_SAAS_POSTGRES_DIR/lib/backend.sh"
# shellcheck source=lib/install.sh
source "$_SAAS_POSTGRES_DIR/lib/install.sh"
# shellcheck source=lib/credentials.sh
source "$_SAAS_POSTGRES_DIR/lib/credentials.sh"
# shellcheck source=lib/doctor.sh
source "$_SAAS_POSTGRES_DIR/lib/doctor.sh"
# shellcheck source=lib/database.sh
source "$_SAAS_POSTGRES_DIR/lib/database.sh"
# shellcheck source=lib/integration_common.sh
source "$_SAAS_POSTGRES_DIR/lib/integration_common.sh"
# shellcheck source=lib/vault_integration.sh
source "$_SAAS_POSTGRES_DIR/lib/vault_integration.sh"
# shellcheck source=lib/gitlab_integration.sh
source "$_SAAS_POSTGRES_DIR/lib/gitlab_integration.sh"

_saas_postgres_integrate_help() {
    cat <<'EOF'
Usage: saas postgres integrate TARGET [OPTIONS]

Targets:
  vault    Apply, into this postgres cluster, the manifests 'saas vault
           integrate postgres' generated on the Vault side, see
           'saas postgres integrate vault --help'
  gitlab   Wire this postgres release up as the database for a GitLab
           instance, see 'saas postgres integrate gitlab --help'
EOF
}

_saas_postgres_integrate() {
    local target="${1:-}"
    [ $# -gt 0 ] && shift
    case "$target" in
        vault)  _saas_postgres_integrate_vault "$@" ;;
        gitlab) _saas_postgres_integrate_gitlab "$@" ;;
        ""|-h|--help|help)
            _saas_postgres_integrate_help
            ;;
        *)
            _saas_log_err "Unknown integration target: 'integrate ${target}'"
            _saas_postgres_integrate_help >&2
            return 1
            ;;
    esac
}

_saas_postgres_help() {
    cat <<'EOF'
Usage: saas postgres SUBCOMMAND [OPTIONS]
(also: saas postgresql SUBCOMMAND [OPTIONS] - 'postgresql' is a pure alias, identical in every way)

Standalone PostgreSQL on Kubernetes: installs from scratch (local kind
cluster or an existing cluster), TLS enforced on every connection,
manages its lifecycle, lets you manage databases/roles directly, and
wires it up as a credential-managed backend for Vault or as GitLab's
external database.

Subcommands:
  install       Install (or update) PostgreSQL, see 'saas postgres
                install --help'
  status        Status of an installation
  credentials   Connection info and admin user/password
  up            Recreate the kind cluster and reinstall (after 'down')
  down          Destroy the kind cluster, preserving the data (suspend)
  delete        Full uninstall
  database      Manage databases/roles, see 'saas postgres database --help'
  doctor        Diagnose (and, with --fix, repair) a broken install
  integrate     Wire this postgres up for Vault or GitLab, see
                'saas postgres integrate --help'

Examples:
  saas postgres install
  saas postgres status
  saas postgres credentials
  saas postgres database create myapp
  saas postgres integrate gitlab --gitlab-release gitlab
  saas postgres down
  saas postgres up
  saas postgres doctor
EOF
}

_saas_postgres() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift

    case "$subcommand" in
        install)      _saas_postgres_install "$@" ;;
        status)       _saas_postgres_status "$@" ;;
        credentials)  _saas_postgres_credentials "$@" ;;
        up)           _saas_postgres_up "$@" ;;
        down)         _saas_postgres_down "$@" ;;
        delete)       _saas_postgres_delete "$@" ;;
        database)     _saas_postgres_database "$@" ;;
        doctor)       _saas_postgres_doctor "$@" ;;
        integrate)    _saas_postgres_integrate "$@" ;;
        ""|-h|--help|help)
            _saas_postgres_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'postgres ${subcommand}'"
            _saas_postgres_help >&2
            return 1
            ;;
    esac
}
