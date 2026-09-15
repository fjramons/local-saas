# --- Management of the underlying cluster for 'saas vault': either a kind cluster created/managed
# by us (via 'saas cluster', or the legacy 'kind_cluster' function if USE_KIND_CLUSTER_FUNCTION=true,
# see the shared _saas_cluster_backend_* in lib/common.sh), or an existing cluster the active
# kubeconfig already points at. Unlike services/gitlab/lib/cluster.sh, no CoreDNS patching is
# needed here: gitlab needs it because CI jobs running INSIDE its own cluster must resolve
# gitlab's own public domain; nothing running inside Vault's own cluster needs to resolve
# Vault's own external domain, so there's nothing to patch.

_saas_vault_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

_saas_vault_cluster_create() { _saas_cluster_backend_create "$@"; }
_saas_vault_cluster_delete() { _saas_cluster_backend_delete "$@"; }
_saas_vault_cluster_use()    { _saas_cluster_backend_use "$@"; }
_saas_vault_cluster_exists() { _saas_cluster_backend_exists "$@"; }
