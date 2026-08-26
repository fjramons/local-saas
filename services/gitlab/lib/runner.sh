# --- GitLab Runner (Kubernetes executor) for 'saas gitlab', integrated into 'install'. Registration no longer uses "registration tokens" (deprecated): a 'root' Personal Access Token is minted via 'gitlab-rails runner' in the toolbox pod, and it's used to request a runner authentication token (glrt-…) from the POST /user/runners API, the same flow GitLab documents for automating runner creation.
#
# The runner (and the initial registration) use the configured PUBLIC domain (global.hosts.domain), not an internal Service. Verified in practice that it has to be this way: GitLab always uses that same domain as CI_SERVER_URL/repo_url for the 'git clone' each CI job does inside its own pod, so even if the runner itself could talk to an internal Service, the jobs would still try to resolve the public domain. That's why that domain has to genuinely resolve FROM INSIDE the cluster (see '_saas_gitlab_cluster_patch_coredns' in cluster.sh, which in --cluster-mode kind points the domain at ingress-nginx's ClusterIP), and with --tls self-signed, the runner additionally needs to trust our self-signed CA (--set certsSecretName, see below). Without both at once the job fails with "Could not resolve host" or a TLS error.

_SAAS_GITLAB_RUNNER_HELM_REPO_NAME="gitlab"

# _saas_gitlab_runner_mint_root_pat NAMESPACE RELEASE
# Prints a one-off root PAT to stdout (scopes api + create_runner, expires in 1 day). Never persisted anywhere.
_saas_gitlab_runner_mint_root_pat() {
    local ns="$1" release="$2"
    local toolbox_pod
    toolbox_pod="$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep -m1 "${release}-toolbox" | sed 's#^pod/##')"
    [ -n "$toolbox_pod" ] || { _saas_log_err "Could not find '$release''s toolbox pod in namespace '$ns'."; return 1; }

    local script='
u = User.find_by_username("root")
t = u.personal_access_tokens.create(scopes: ["api", "create_runner"], name: "saas-gitlab-bootstrap", expires_at: 1.day.from_now)
if t.persisted?
  puts t.token
else
  STDERR.puts t.errors.full_messages.join(", ")
  exit 1
end
'
    kubectl -n "$ns" exec "$toolbox_pod" -- gitlab-rails runner "$script" 2>/dev/null
}

# _saas_gitlab_runner_register NAMESPACE RELEASE DOMAIN
# Prints the runner authentication token (glrt-…) to stdout. -k: the ephemeral pod making this one call has no need to trust the self-signed CA (unlike the runner/jobs, which need to persistently, see certsSecretName in _saas_gitlab_runner_install).
_saas_gitlab_runner_register() {
    local ns="$1" release="$2" domain="$3"
    local pat
    pat="$(_saas_gitlab_runner_mint_root_pat "$ns" "$release")" || return 1
    [ -n "$pat" ] || { _saas_log_err "Could not mint a root access token."; return 1; }

    local response
    response="$(kubectl -n "$ns" run "saas-gitlab-runner-register-$$" --rm -i --restart=Never \
        --image=curlimages/curl:8.11.0 --quiet -- \
        curl -sS -k --request POST "https://${domain}/api/v4/user/runners" \
            --header "PRIVATE-TOKEN: ${pat}" \
            --data "runner_type=instance_type" \
            --data "description=saas-gitlab (${release})" \
            --data "run_untagged=true" 2>/dev/null)"

    local token
    token="$(echo "$response" | jq -r '.token // empty' 2>/dev/null)"
    if [ -z "$token" ]; then
        _saas_log_err "Could not register the runner: $response"
        return 1
    fi
    echo "$token"
}

# _saas_gitlab_runner_install NAMESPACE RELEASE DOMAIN
_saas_gitlab_runner_install() {
    local ns="$1" release="$2" domain="$3"

    local token
    token="$(_saas_gitlab_runner_register "$ns" "$release" "$domain")" || return 1

    local tls_secret="${release}-gitlab-tls" certs_secret="${release}-runner-certs"
    if kubectl -n "$ns" get secret "$tls_secret" >/dev/null 2>&1; then
        local crt
        crt="$(kubectl -n "$ns" get secret "$tls_secret" -o jsonpath='{.data.tls\.crt}' | base64 -d)"
        kubectl -n "$ns" create secret generic "$certs_secret" \
            --from-literal="${domain}.crt=${crt}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    fi

    helm upgrade --install "${release}-runner" "${_SAAS_GITLAB_RUNNER_HELM_REPO_NAME}/gitlab-runner" \
        --namespace "$ns" \
        --set gitlabUrl="https://${domain}/" \
        --set runnerToken="$token" \
        --set rbac.create=true \
        --set rbac.serviceAccount.create=true \
        --set runners.executor=kubernetes \
        --set certsSecretName="$certs_secret" \
        --timeout 5m --wait

    local helm_status=$?
    if [ "$helm_status" -eq 0 ]; then
        _saas_gitlab_state_save_key "$release" "RUNNER_TOKEN" "$token"
        _saas_log_ok "GitLab Runner registered and ready."
    fi
    return "$helm_status"
}

_saas_gitlab_runner_help() {
    cat <<'EOF'
Usage: saas gitlab runner SUBCOMMAND [RELEASE]

Subcommands:
  status        Show the status of the gitlab-runner Deployment
  reregister    Mint a new runner authentication token and reinstall
                the gitlab-runner chart with it (use this if the
                runner ended up orphaned, e.g. after recreating
                GitLab by hand)

Examples:
  saas gitlab runner status
  saas gitlab runner reregister demo
EOF
}

_saas_gitlab_runner() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift
    local release="${1:-$(_saas_gitlab_suggest_release)}"

    case "$sub" in
        status)
            _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
            kubectl -n "$SAAS_GITLAB_STATE_NAMESPACE" get deployment "${release}-runner-gitlab-runner" 2>/dev/null \
                || _saas_log_warn "Could not find the runner's Deployment (--no-runner at install time?)."
            ;;
        reregister)
            _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
            _saas_gitlab_runner_install "$SAAS_GITLAB_STATE_NAMESPACE" "$release" "$SAAS_GITLAB_STATE_DOMAIN"
            ;;
        ""|-h|--help|help)
            _saas_gitlab_runner_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'runner $sub'"
            _saas_gitlab_runner_help >&2
            return 1
            ;;
    esac
}
