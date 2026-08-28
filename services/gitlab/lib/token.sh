# --- Personal Access Token (PAT) minting for 'saas gitlab'. Shared by 'saas gitlab token mint' (this file) and runner.sh's own bootstrap registration, both via the same 'gitlab-rails runner' exec into the toolbox pod (the toolbox pod is why datastore.sh always creates '<release>-datastore-s3cfg', see its own comment).

# _saas_gitlab_mint_pat NAMESPACE RELEASE USERNAME SCOPES EXPIRY_DAYS
# Prints a one-off Personal Access Token to stdout. SCOPES is a comma-separated list (e.g. "api,create_runner"). Never persisted anywhere: callers that need to reuse it must mint again.
_saas_gitlab_mint_pat() {
    local ns="$1" release="$2" username="$3" scopes="$4" expiry_days="$5"
    local toolbox_pod
    toolbox_pod="$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep -m1 "${release}-toolbox" | sed 's#^pod/##')"
    [ -n "$toolbox_pod" ] || { _saas_log_err "Could not find '$release''s toolbox pod in namespace '$ns'."; return 1; }

    local scopes_rb="" scope
    local -a scope_arr
    IFS=',' read -ra scope_arr <<< "$scopes"
    for scope in "${scope_arr[@]}"; do
        scopes_rb+="${scopes_rb:+, }\"${scope}\""
    done

    local script
    script="$(cat <<RUBY
u = User.find_by_username('${username}')
if u.nil?
  STDERR.puts 'User not found: ${username}'
  exit 1
end
t = u.personal_access_tokens.create(scopes: [${scopes_rb}], name: 'saas-gitlab-token-mint', expires_at: ${expiry_days}.days.from_now)
if t.persisted?
  puts t.token
else
  STDERR.puts t.errors.full_messages.join(', ')
  exit 1
end
RUBY
)"
    kubectl -n "$ns" exec "$toolbox_pod" -- gitlab-rails runner "$script" 2>/dev/null
}

_saas_gitlab_valid_token_username() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]; }
_saas_gitlab_valid_token_scopes()   { [[ "$1" =~ ^[a-zA-Z0-9_]+(,[a-zA-Z0-9_]+)*$ ]]; }

_saas_gitlab_token_help() {
    cat <<'EOF'
Usage: saas gitlab token SUBCOMMAND [ARGS]

Subcommands:
  mint   Mint a Personal Access Token and print it to stdout

Examples:
  saas gitlab token mint
  saas gitlab token mint demo root api
EOF
}

_saas_gitlab_token_mint_help() {
    cat <<'EOF'
Usage: saas gitlab token mint [RELEASE] [USERNAME] [SCOPES] [EXPIRY_DAYS]

Mints a Personal Access Token for USERNAME (default: root) with SCOPES
(comma-separated, default: api) via 'gitlab-rails runner' in the
toolbox pod, and prints it to stdout. Not persisted anywhere: run it
again to mint a new one.

Options:
  -h, --help   Show this help

Examples:
  saas gitlab token mint
  saas gitlab token mint demo root api
  saas gitlab token mint demo root api,create_runner 7
EOF
}

_saas_gitlab_token() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        mint) _saas_gitlab_token_mint "$@" ;;
        ""|-h|--help|help)
            _saas_gitlab_token_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'token $sub'"
            _saas_gitlab_token_help >&2
            return 1
            ;;
    esac
}

_saas_gitlab_token_mint() {
    case "${1:-}" in -h|--help) _saas_gitlab_token_mint_help; return 0 ;; esac
    local release="${1:-$(_saas_gitlab_suggest_release)}"
    local username="${2:-root}"
    local scopes="${3:-api}"
    local expiry_days="${4:-1}"

    _saas_gitlab_valid_token_username "$username" || { _saas_log_err "Invalid username: '$username'."; return 1; }
    _saas_gitlab_valid_token_scopes "$scopes" || { _saas_log_err "Invalid scopes: '$scopes' (comma-separated, e.g. 'api,create_runner')."; return 1; }
    [[ "$expiry_days" =~ ^[0-9]+$ ]] || { _saas_log_err "Invalid expiry: '$expiry_days' (must be a whole number of days)."; return 1; }

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }

    _saas_gitlab_mint_pat "$SAAS_GITLAB_STATE_NAMESPACE" "$release" "$username" "$scopes" "$expiry_days"
}
