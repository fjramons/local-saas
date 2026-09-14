# --- Cluster-wide, one-time install of Stakater Reloader for 'saas vault'. cert-manager's own
# ensure-installed logic lives in lib/common.sh (_saas_ensure_certmanager, shared with gitlab, see
# CLAUDE.md's Design notes); Reloader stays here because gitlab doesn't use it today, so there's
# nothing yet to share. Reloader restarts the OpenBao StatefulSet's pods automatically whenever
# cert-manager rotates the internal leaf certificate (see tls.sh), via the
# 'secret.reloader.stakater.com/reload' annotation set on the pod template in values/*.yaml.tpl.
#
# Pinned deliberately, unlike openbao/openbao or jetstack/cert-manager (versions.sh, always
# "latest stable"): a third-party operator this repo doesn't track closely could silently change
# CRD schemas or RBAC between runs, same reasoning as gitlab's CNPG/redis-operator/DuckDNS-webhook
# pins (services/gitlab/lib/operators.sh).

_SAAS_VAULT_RELOADER_HELM_REPO_URL="https://stakater.github.io/stakater-charts"
_SAAS_VAULT_RELOADER_CHART_VERSION="2.2.17"    # app v1.4.22; verify with 'helm search repo stakater/reloader --versions' before bumping
_SAAS_VAULT_RELOADER_NAMESPACE="reloader"

# _saas_vault_operator_reloader_ensure
# Idempotent via 'helm status' (Reloader has no CRD of its own to probe, unlike cert-manager/CNPG/
# the redis-operator).
_saas_vault_operator_reloader_ensure() {
    if helm status reloader --namespace "$_SAAS_VAULT_RELOADER_NAMESPACE" >/dev/null 2>&1; then
        _saas_log_info "Stakater Reloader is already installed."
        return 0
    fi

    _saas_log_step "Installing Stakater Reloader…"
    if ! helm repo list -o json 2>/dev/null | jq -e '.[]? | select(.name == "stakater")' >/dev/null; then
        helm repo add stakater "$_SAAS_VAULT_RELOADER_HELM_REPO_URL" >/dev/null || return 1
    fi
    helm repo update stakater >/dev/null || return 1

    helm upgrade --install reloader stakater/reloader \
        --namespace "$_SAAS_VAULT_RELOADER_NAMESPACE" --create-namespace \
        --version "$_SAAS_VAULT_RELOADER_CHART_VERSION" --wait --timeout 180s
}
