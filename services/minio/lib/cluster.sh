# --- Management of the underlying cluster for 'saas minio': either a kind cluster created/managed
# by us (via 'saas cluster', or the legacy 'kind_cluster' function if USE_KIND_CLUSTER_FUNCTION=true,
# see the shared _saas_cluster_backend_* in lib/common.sh), or an existing cluster the active
# kubeconfig already points at. Same shape as services/vault/lib/cluster.sh: no CoreDNS patching
# needed here either, MinIO's own domain is only ever used from outside the cluster (browsers/S3
# clients), never resolved from inside a pod the way GitLab's CI jobs need to resolve GitLab's own
# domain.

_saas_minio_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

_saas_minio_cluster_create() { _saas_cluster_backend_create "$@"; }
_saas_minio_cluster_delete() { _saas_cluster_backend_delete "$@"; }
_saas_minio_cluster_use()    { _saas_cluster_backend_use "$@"; }
_saas_minio_cluster_exists() { _saas_cluster_backend_exists "$@"; }
