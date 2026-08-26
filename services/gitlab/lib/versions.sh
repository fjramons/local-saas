# --- Available versions of the gitlab/gitlab chart (official Helm repo).

_SAAS_GITLAB_HELM_REPO_NAME="gitlab"
_SAAS_GITLAB_HELM_REPO_URL="https://charts.gitlab.io"

# _saas_gitlab_helm_repo_ensure
# Idempotent: does nothing if the Helm repo is already added with that URL.
_saas_gitlab_helm_repo_ensure() {
    if ! helm repo list -o json 2>/dev/null | jq -e --arg n "$_SAAS_GITLAB_HELM_REPO_NAME" '.[]? | select(.name == $n)' >/dev/null; then
        helm repo add "$_SAAS_GITLAB_HELM_REPO_NAME" "$_SAAS_GITLAB_HELM_REPO_URL" >/dev/null || return 1
    fi
    helm repo update "$_SAAS_GITLAB_HELM_REPO_NAME" >/dev/null
}

# _saas_gitlab_versions_rows
# Prints "CHART_VERSION\tAPP_VERSION" one row per line, most recent first (the order 'helm search repo --versions' already returns).
_saas_gitlab_versions_rows() {
    _saas_gitlab_helm_repo_ensure || return 1
    helm search repo "$_SAAS_GITLAB_HELM_REPO_NAME/gitlab" --versions -o json \
        | jq -r '.[] | "\(.version)\t\(.app_version)"'
}

# _saas_gitlab_versions_list [LIMIT]
_saas_gitlab_versions_list() {
    local limit="${1:-15}"
    local rows
    rows="$(_saas_gitlab_versions_rows)" || { _saas_log_err "Could not query the GitLab Helm repo."; return 1; }

    echo "GitLab chart      GitLab version"
    echo "$rows" | head -n "$limit" | awk -F'\t' 'NR==1{print $1"\t"$2"\t(latest stable)"; next} {print}' \
        | column -t -s $'\t'
}

# _saas_gitlab_version_resolve VERSION
# VERSION empty or "latest" -> most recent chart version. Otherwise, validates it exists in the Helm repo (clear error if not).
_saas_gitlab_version_resolve() {
    local version="$1"
    local rows
    rows="$(_saas_gitlab_versions_rows)" || return 1

    if [ -z "$version" ] || [ "$version" = "latest" ]; then
        echo "$rows" | head -1 | cut -f1
        return 0
    fi

    if echo "$rows" | cut -f1 | grep -qx "$version"; then
        echo "$version"
        return 0
    fi

    _saas_log_err "Chart version '$version' not found in the GitLab Helm repo."
    _saas_log_err "Check the available ones with: saas gitlab versions"
    return 1
}

_saas_gitlab_versions_help() {
    cat <<'EOF'
Usage: saas gitlab versions [OPTIONS]

Lists the available versions of the gitlab/gitlab chart (official Helm
repo), with the GitLab version each one packages. The first row is the
one 'saas gitlab install' uses when --version is omitted (equivalent to
'latest').

Options:
      --limit N   Number of versions to show (default: 15)
  -h, --help      Show this help

Examples:
  saas gitlab versions
  saas gitlab versions --limit 5
EOF
}

_saas_gitlab_versions() {
    local limit=15
    local args
    args=$(getopt -o h -l limit:,help --name saas_gitlab_versions -- "$@") || { _saas_gitlab_versions_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --limit) limit="$2"; shift 2 ;;
            -h|--help) _saas_gitlab_versions_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    _saas_gitlab_versions_list "$limit"
}
