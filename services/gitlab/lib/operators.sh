# --- Cluster-wide, one-time installs of third-party operators/webhooks used by 'saas gitlab'.
#
# Unlike datastore.sh (per-release resources, named after $release), everything here is a
# cluster-wide singleton: installed once per cluster, safe to call repeatedly from any release's
# install/up. Exact versions are pinned as constants below because reproducibility matters here,
# unlike gitlab/gitlab or jetstack/cert-manager (versions.sh, tls.sh), which always resolve to
# "latest stable".
#
# Bitnami's charts are deliberately NOT used anywhere in this repo: since August 2025 its free tier
# only offers ':latest' (no version pinning) for a reduced image set, with the full catalog behind a
# paid subscription, incompatible with pinning exact versions for reproducible builds.

_SAAS_GITLAB_REDIS_OPERATOR_HELM_REPO_URL="https://ot-container-kit.github.io/helm-charts/"
_SAAS_GITLAB_REDIS_OPERATOR_CHART_VERSION="0.26.1"    # app 0.26.0; verify with 'helm search repo ot-helm/redis-operator --versions' before bumping
_SAAS_GITLAB_REDIS_OPERATOR_NAMESPACE="redis-operator-system"

# DuckDNS ACME webhook: this exact chart is a one-off, explicitly-approved exception to
# "cert-manager-native only" DNS-01 providers (see tls.sh). Cloudflare and any future provider
# must NOT gain a third-party webhook without an equally explicit decision. Distributed via OCI
# (no 'helm repo add' needed), a continuation of the nolte to ebrianne to cobexer lineage of this
# webhook; the earlier ebrianne fork is dead (no release since Dec 2023, its GitHub Pages chart
# repo returns 404). Verified live before choosing cobexer's (actively maintained, Renovate-bot
# dependency updates, pushed within days at the time of writing).
_SAAS_GITLAB_DUCKDNS_WEBHOOK_CHART="oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns"
_SAAS_GITLAB_DUCKDNS_WEBHOOK_CHART_VERSION="2.0.0"    # verify with 'helm show chart oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns --version X' before bumping
_SAAS_GITLAB_DUCKDNS_WEBHOOK_RELEASE_NAME="cert-manager-webhook-duckdns"
_SAAS_GITLAB_DUCKDNS_WEBHOOK_SECRET_NAME="cert-manager-webhook-duckdns-token"
_SAAS_GITLAB_DUCKDNS_WEBHOOK_GROUP_NAME="acme.duckdns.org"
_SAAS_GITLAB_DUCKDNS_WEBHOOK_SOLVER_NAME="duckdns"

# _saas_gitlab_operator_cnpg_ensure
# One-line wrapper around the shared _saas_ensure_cnpg_operator (lib/common.sh): promoted there the
# moment services/postgres/ needed the exact same install logic with zero variation, same "rule of
# three" precedent already documented in CLAUDE.md for _saas_ensure_certmanager/_saas_cluster_backend_*.
_saas_gitlab_operator_cnpg_ensure() { _saas_ensure_cnpg_operator; }

# _saas_gitlab_operator_redis_ensure
# Idempotent: does nothing if OT-CONTAINER-KIT's redis-operator CRDs are already installed.
_saas_gitlab_operator_redis_ensure() {
    if kubectl get crd redisreplications.redis.redis.opstreelabs.in >/dev/null 2>&1; then
        _saas_log_info "Redis operator is already installed."
        return 0
    fi

    _saas_log_step "Installing the OT-CONTAINER-KIT redis-operator (Redis HA)…"
    if ! helm repo list -o json 2>/dev/null | jq -e '.[]? | select(.name == "ot-helm")' >/dev/null; then
        helm repo add ot-helm "$_SAAS_GITLAB_REDIS_OPERATOR_HELM_REPO_URL" >/dev/null || return 1
    fi
    helm repo update ot-helm >/dev/null || return 1

    helm upgrade --install redis-operator ot-helm/redis-operator \
        --namespace "$_SAAS_GITLAB_REDIS_OPERATOR_NAMESPACE" --create-namespace \
        --version "$_SAAS_GITLAB_REDIS_OPERATOR_CHART_VERSION" --wait --timeout 180s
}

# _saas_gitlab_operator_duckdns_webhook_ensure TOKEN
# The webhook's own RBAC scopes its Secret-read permission to exactly one fixed secret name
# (verified in the chart's rbac.yaml), so this is a single shared, cluster-wide secret, not one
# per release/issuer. The secret is always re-applied (even if the Helm release already exists) so
# that rotating the DuckDNS account token on a later install/up takes effect; if multiple releases
# use --dns-provider duckdns in the same cluster, they necessarily share one DuckDNS account token.
# The last install/up to run updates it for all of them (documented behavior, not a bug).
_saas_gitlab_operator_duckdns_webhook_ensure() {
    local token="$1"

    kubectl -n cert-manager create secret generic "$_SAAS_GITLAB_DUCKDNS_WEBHOOK_SECRET_NAME" \
        --from-literal=token="$token" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    if helm status "$_SAAS_GITLAB_DUCKDNS_WEBHOOK_RELEASE_NAME" --namespace cert-manager >/dev/null 2>&1; then
        _saas_log_info "The DuckDNS cert-manager webhook is already installed."
        return 0
    fi

    _saas_log_step "Installing the DuckDNS cert-manager webhook…"
    helm upgrade --install "$_SAAS_GITLAB_DUCKDNS_WEBHOOK_RELEASE_NAME" "$_SAAS_GITLAB_DUCKDNS_WEBHOOK_CHART" \
        --version "$_SAAS_GITLAB_DUCKDNS_WEBHOOK_CHART_VERSION" \
        --namespace cert-manager \
        --set fullnameOverride="$_SAAS_GITLAB_DUCKDNS_WEBHOOK_RELEASE_NAME" \
        --set secret.existingSecret=true \
        --set secret.existingSecretName="$_SAAS_GITLAB_DUCKDNS_WEBHOOK_SECRET_NAME" \
        --set clusterIssuer.staging.create=false \
        --set clusterIssuer.production.create=false \
        --wait --timeout 180s
}
