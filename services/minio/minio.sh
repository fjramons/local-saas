# --- saas minio: standalone, S3-compatible MinIO object storage on Kubernetes (subcommand
# dispatcher). All paths are resolved relative to this file (BASH_SOURCE), never hardcoded. Also
# reachable as 'saas object-storage' (see saas.sh): both spellings dispatch here identically, same
# convention as 'vault'/'openbao'.

_SAAS_MINIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=lib/state.sh
source "$_SAAS_MINIO_DIR/lib/state.sh"
# shellcheck source=lib/cluster.sh
source "$_SAAS_MINIO_DIR/lib/cluster.sh"
# shellcheck source=lib/backend.sh
source "$_SAAS_MINIO_DIR/lib/backend.sh"
# shellcheck source=lib/tls.sh
source "$_SAAS_MINIO_DIR/lib/tls.sh"
# shellcheck source=lib/install.sh
source "$_SAAS_MINIO_DIR/lib/install.sh"
# shellcheck source=lib/credentials.sh
source "$_SAAS_MINIO_DIR/lib/credentials.sh"
# shellcheck source=lib/doctor.sh
source "$_SAAS_MINIO_DIR/lib/doctor.sh"
# shellcheck source=lib/bucket.sh
source "$_SAAS_MINIO_DIR/lib/bucket.sh"
# shellcheck source=lib/integration_common.sh
source "$_SAAS_MINIO_DIR/lib/integration_common.sh"
# shellcheck source=lib/vault_integration.sh
source "$_SAAS_MINIO_DIR/lib/vault_integration.sh"
# shellcheck source=lib/gitlab_integration.sh
source "$_SAAS_MINIO_DIR/lib/gitlab_integration.sh"

_saas_minio_integrate_help() {
    cat <<'EOF'
Usage: saas minio integrate TARGET [OPTIONS]

Targets:
  vault    Apply, into this MinIO cluster, the manifests 'saas vault
           integrate minio' generated on the Vault side, see
           'saas minio integrate vault --help'
  gitlab   Wire this MinIO release up as object storage for a GitLab
           instance, see 'saas minio integrate gitlab --help'
EOF
}

_saas_minio_integrate() {
    local target="${1:-}"
    [ $# -gt 0 ] && shift
    case "$target" in
        vault)  _saas_minio_integrate_vault "$@" ;;
        gitlab) _saas_minio_integrate_gitlab "$@" ;;
        ""|-h|--help|help)
            _saas_minio_integrate_help
            ;;
        *)
            _saas_log_err "Unknown integration target: 'integrate ${target}'"
            _saas_minio_integrate_help >&2
            return 1
            ;;
    esac
}

_saas_minio_help() {
    cat <<'EOF'
Usage: saas minio SUBCOMMAND [OPTIONS]
(also: saas object-storage SUBCOMMAND [OPTIONS] - 'object-storage' is a pure alias, identical in every way)

Standalone, S3-compatible MinIO object storage on Kubernetes: installs
from scratch (local kind cluster or an existing cluster), manages its
lifecycle, lets you manage buckets directly, and wires it up as a
credential-managed backend for Vault or as GitLab's object storage.

Subcommands:
  install       Install (or update) MinIO, see 'saas minio install --help'
  status        Status of an installation
  credentials   Console/S3 URLs and root user/password
  up            Recreate the kind cluster and reinstall (after 'down')
  down          Destroy the kind cluster, preserving the data (suspend)
  delete        Full uninstall
  bucket        Manage buckets, see 'saas minio bucket --help'
  doctor        Diagnose (and, with --fix, repair) a broken install
  integrate     Wire this MinIO up for Vault or GitLab, see
                'saas minio integrate --help'

Examples:
  saas minio install
  saas minio status
  saas minio credentials
  saas minio bucket create my-bucket
  saas minio integrate gitlab --gitlab-release gitlab
  saas minio down
  saas minio up
  saas minio doctor
EOF
}

_saas_minio() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift

    case "$subcommand" in
        install)      _saas_minio_install "$@" ;;
        status)       _saas_minio_status "$@" ;;
        credentials)  _saas_minio_credentials "$@" ;;
        up)           _saas_minio_up "$@" ;;
        down)         _saas_minio_down "$@" ;;
        delete)       _saas_minio_delete "$@" ;;
        bucket)       _saas_minio_bucket "$@" ;;
        doctor)       _saas_minio_doctor "$@" ;;
        integrate)    _saas_minio_integrate "$@" ;;
        ""|-h|--help|help)
            _saas_minio_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'minio ${subcommand}'"
            _saas_minio_help >&2
            return 1
            ;;
    esac
}
