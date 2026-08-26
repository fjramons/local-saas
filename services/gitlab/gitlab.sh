# --- saas gitlab: self-hosted GitLab on Kubernetes (subcommand dispatcher). All paths are resolved relative to this file (BASH_SOURCE), never hardcoded.

_SAAS_GITLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=lib/state.sh
source "$_SAAS_GITLAB_DIR/lib/state.sh"
# shellcheck source=lib/cluster.sh
source "$_SAAS_GITLAB_DIR/lib/cluster.sh"
# shellcheck source=lib/versions.sh
source "$_SAAS_GITLAB_DIR/lib/versions.sh"
# shellcheck source=lib/operators.sh
source "$_SAAS_GITLAB_DIR/lib/operators.sh"
# shellcheck source=lib/datastore.sh
source "$_SAAS_GITLAB_DIR/lib/datastore.sh"
# shellcheck source=lib/datastore-ha.sh
source "$_SAAS_GITLAB_DIR/lib/datastore-ha.sh"
# shellcheck source=lib/tls.sh
source "$_SAAS_GITLAB_DIR/lib/tls.sh"
# shellcheck source=lib/install.sh
source "$_SAAS_GITLAB_DIR/lib/install.sh"
# shellcheck source=lib/runner.sh
source "$_SAAS_GITLAB_DIR/lib/runner.sh"
# shellcheck source=lib/ssh.sh
source "$_SAAS_GITLAB_DIR/lib/ssh.sh"
# shellcheck source=lib/credentials.sh
source "$_SAAS_GITLAB_DIR/lib/credentials.sh"

_saas_gitlab_help() {
    cat <<'EOF'
Usage: saas gitlab SUBCOMMAND [OPTIONS]

Self-hosted GitLab on Kubernetes: installs from scratch (local kind
cluster or an existing cluster), manages its lifecycle, and gives access
to credentials/URL/SSH/CI.

Subcommands:
  install       Install (or update) GitLab, see 'saas gitlab install --help'
  versions      List available chart versions
  status        Status of an installation
  credentials   URL and how to get the root password
  up            Recreate the kind cluster and reinstall (after 'down')
  down          Destroy the kind cluster, preserving the data (suspend)
  delete        Full uninstall
  ssh-config    ~/.ssh/config block to clone without touching port 22
  runner        GitLab Runner management (status, reregister)

Examples:
  saas gitlab install
  saas gitlab install --help
  saas gitlab status
  saas gitlab credentials
  saas gitlab down
  saas gitlab up
EOF
}

_saas_gitlab() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift

    case "$subcommand" in
        install)      _saas_gitlab_install "$@" ;;
        versions)     _saas_gitlab_versions "$@" ;;
        status)       _saas_gitlab_status "$@" ;;
        credentials)  _saas_gitlab_credentials "$@" ;;
        up)           _saas_gitlab_up "$@" ;;
        down)         _saas_gitlab_down "$@" ;;
        delete)       _saas_gitlab_delete "$@" ;;
        ssh-config)   _saas_gitlab_ssh_config "$@" ;;
        runner)       _saas_gitlab_runner "$@" ;;
        ""|-h|--help|help)
            _saas_gitlab_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'gitlab ${subcommand}'"
            _saas_gitlab_help >&2
            return 1
            ;;
    esac
}
