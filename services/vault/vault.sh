# --- saas vault: self-hosted OpenBao on Kubernetes (subcommand dispatcher). All paths are
# resolved relative to this file (BASH_SOURCE), never hardcoded. Also reachable as 'saas openbao'
# (see saas.sh): both spellings dispatch here identically, there is no separate '_saas_openbao_*'
# anything and default names always stay "vault" regardless of which one was typed.

_SAAS_VAULT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=lib/state.sh
source "$_SAAS_VAULT_DIR/lib/state.sh"
# shellcheck source=lib/secrets.sh
source "$_SAAS_VAULT_DIR/lib/secrets.sh"
# shellcheck source=lib/cluster.sh
source "$_SAAS_VAULT_DIR/lib/cluster.sh"
# shellcheck source=lib/versions.sh
source "$_SAAS_VAULT_DIR/lib/versions.sh"
# shellcheck source=lib/operators.sh
source "$_SAAS_VAULT_DIR/lib/operators.sh"
# shellcheck source=lib/tls.sh
source "$_SAAS_VAULT_DIR/lib/tls.sh"
# shellcheck source=lib/init.sh
source "$_SAAS_VAULT_DIR/lib/init.sh"
# shellcheck source=lib/install.sh
source "$_SAAS_VAULT_DIR/lib/install.sh"
# shellcheck source=lib/credentials.sh
source "$_SAAS_VAULT_DIR/lib/credentials.sh"
# shellcheck source=lib/doctor.sh
source "$_SAAS_VAULT_DIR/lib/doctor.sh"
# shellcheck source=lib/integration_common.sh
source "$_SAAS_VAULT_DIR/lib/integration_common.sh"
# shellcheck source=lib/gitlab_integration.sh
source "$_SAAS_VAULT_DIR/lib/gitlab_integration.sh"
# shellcheck source=lib/eso_integration.sh
source "$_SAAS_VAULT_DIR/lib/eso_integration.sh"

_saas_vault_integrate_help() {
    cat <<'EOF'
Usage: saas vault integrate TARGET [OPTIONS]

Targets:
  gitlab   Wire this Vault release up for a GitLab instance, see
           'saas vault integrate gitlab --help'
  eso      Wire this Vault release up for an arbitrary External
           Secrets Operator installation, see 'saas vault integrate
           eso --help'
EOF
}

_saas_vault_integrate() {
    local target="${1:-}"
    [ $# -gt 0 ] && shift
    case "$target" in
        gitlab) _saas_vault_integrate_gitlab "$@" ;;
        eso)    _saas_vault_integrate_eso "$@" ;;
        ""|-h|--help|help)
            _saas_vault_integrate_help
            ;;
        *)
            _saas_log_err "Unknown integration target: 'integrate ${target}'"
            _saas_vault_integrate_help >&2
            return 1
            ;;
    esac
}

_saas_vault_help() {
    cat <<'EOF'
Usage: saas vault SUBCOMMAND [OPTIONS]
(also: saas openbao SUBCOMMAND [OPTIONS] - 'openbao' is a pure alias, identical in every way)

Self-hosted OpenBao (a Vault-compatible secrets manager) on Kubernetes:
installs from scratch (local kind cluster or an existing cluster) with
fully automated init/unseal, manages its lifecycle, and wires it up as
a secrets backend for a GitLab instance or any External Secrets
Operator installation.

Subcommands:
  install       Install (or update) Vault, see 'saas vault install --help'
  versions      List available chart versions
  status        Status of an installation
  credentials   URL and (opt-in) root token/unseal keys
  unseal        Re-apply saved unseal keys to a sealed instance
  up            Recreate the kind cluster and reinstall (after 'down')
  down          Destroy the kind cluster, preserving the data (suspend)
  delete        Full uninstall
  doctor        Diagnose (and, with --fix, repair) a broken install
  integrate     Wire this Vault up for GitLab or ESO, see
                'saas vault integrate --help'

Examples:
  saas vault install
  saas vault status
  saas vault credentials
  saas vault integrate gitlab --gitlab-release gitlab
  saas vault down
  saas vault up
  saas vault doctor
EOF
}

_saas_vault() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift

    case "$subcommand" in
        install)      _saas_vault_install "$@" ;;
        versions)     _saas_vault_versions "$@" ;;
        status)       _saas_vault_status "$@" ;;
        credentials)  _saas_vault_credentials "$@" ;;
        unseal)       _saas_vault_unseal "$@" ;;
        up)           _saas_vault_up "$@" ;;
        down)         _saas_vault_down "$@" ;;
        delete)       _saas_vault_delete "$@" ;;
        doctor)       _saas_vault_doctor "$@" ;;
        integrate)    _saas_vault_integrate "$@" ;;
        ""|-h|--help|help)
            _saas_vault_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'vault ${subcommand}'"
            _saas_vault_help >&2
            return 1
            ;;
    esac
}
