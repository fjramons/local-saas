# --- Management of the underlying cluster for 'saas postgres': either a kind cluster created/
# managed by us (via 'saas cluster', or the legacy 'kind_cluster' function if
# USE_KIND_CLUSTER_FUNCTION=true, see the shared _saas_cluster_backend_* in lib/common.sh), or an
# existing cluster the active kubeconfig already points at. Same shape as
# services/minio/lib/cluster.sh: no CoreDNS patching needed, PostgreSQL's own domain (used only for
# the Certificate's CN/SAN, see tls.sh) is never resolved from inside a pod, only ever from a host
# psql client via --expose or from another cluster's own in-cluster Service DNS name.

_saas_postgres_valid_cluster_mode() { [[ "$1" == "kind" || "$1" == "existing" ]]; }

_saas_postgres_cluster_create() { _saas_cluster_backend_create "$@"; }
_saas_postgres_cluster_delete() { _saas_cluster_backend_delete "$@"; }
_saas_postgres_cluster_use()    { _saas_cluster_backend_use "$@"; }
_saas_postgres_cluster_exists() { _saas_cluster_backend_exists "$@"; }
