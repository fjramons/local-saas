# --- State of 'saas gitlab' itself (a deliberate exception to kind_cluster's "no state file of its own" convention). Needed because the down/up cycle destroys the whole kind cluster (and with it every Kubernetes object), and it must be possible to recreate an identical install without retyping every flag.
#
# Format: one file per release, 'KEY=value' lines with safe quoting via 'printf %q', meant to be sourced directly.

_saas_gitlab_state_dir() {
    echo "${SAAS_GITLAB_STATE_DIR:-$HOME/.local/state/saas/gitlab}"
}

_saas_gitlab_state_path() {
    local release="$1"
    echo "$(_saas_gitlab_state_dir)/${release}.env"
}

# _saas_gitlab_state_save RELEASE KEY1=value1 KEY2=value2 ...
_saas_gitlab_state_save() {
    local release="$1"; shift
    local dir path
    dir="$(_saas_gitlab_state_dir)"
    path="$(_saas_gitlab_state_path "$release")"
    mkdir -p "$dir" || { _saas_log_err "Could not create $dir"; return 1; }

    local tmp="${path}.tmp.$$"
    : > "$tmp"
    local kv key value
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        printf 'SAAS_GITLAB_STATE_%s=%q\n' "$key" "$value" >> "$tmp"
    done
    mv "$tmp" "$path"
}

# _saas_gitlab_state_load RELEASE
# Sources the state file if it exists (SAAS_GITLAB_STATE_* variables); returns 1 silently if there's no saved state for that release (not an error: it may be the first install).
_saas_gitlab_state_load() {
    local release="$1"
    local path
    path="$(_saas_gitlab_state_path "$release")"
    [ -f "$path" ] || return 1
    # shellcheck disable=SC1090
    source "$path"
}

# _saas_gitlab_state_save_key RELEASE KEY VALUE
# Updates a single key of an already-saved state, preserving the rest (e.g. RUNNER_TOKEN after a runner registration/re-registration that shouldn't touch any other key).
_saas_gitlab_state_save_key() {
    local release="$1" key="$2" value="$3"
    _saas_gitlab_state_load "$release" || return 1

    local -a fields=(RELEASE NAMESPACE CLUSTER_MODE KIND_NAME KIND_WORKERS STORAGE_MODE STORAGE_CLASS
        MODE VERSION DOMAIN TLS ISSUER_NAME CHALLENGE DNS_PROVIDER EMAIL INGRESS_CLASS SSH_HOST_PORT
        RUNNER_ENABLED REGISTRY_ENABLED PAGES_ENABLED PAGES_URL_MODE PSQL_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD
        ROOT_PASSWORD REDIS_PASSWORD OBJECT_STORAGE_MODE STATUS RUNNER_TOKEN)
    local -a pairs=()
    local field current
    for field in "${fields[@]}"; do
        if [ "$field" = "$key" ]; then
            pairs+=("${field}=${value}")
        else
            current="SAAS_GITLAB_STATE_${field}"
            pairs+=("${field}=${!current:-}")
        fi
    done
    _saas_gitlab_state_save "$release" "${pairs[@]}"
}

_saas_gitlab_state_delete() {
    local release="$1"
    rm -f "$(_saas_gitlab_state_path "$release")"
}

_saas_gitlab_state_exists() {
    local release="$1"
    [ -f "$(_saas_gitlab_state_path "$release")" ]
}

# _saas_gitlab_state_list
# Names of releases with saved state (to suggest a default RELEASE in status/credentials/up/down/delete when there's only one).
_saas_gitlab_state_list() {
    local dir f
    dir="$(_saas_gitlab_state_dir)"
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.env; do
        [ -e "$f" ] || continue
        basename "$f" .env
    done
}

# _saas_gitlab_suggest_release
# If there's exactly one release with saved state, suggests it as the default; otherwise falls back to the literal "gitlab".
_saas_gitlab_suggest_release() {
    local -a releases=()
    local r
    while IFS= read -r r; do
        [ -n "$r" ] && releases+=("$r")
    done < <(_saas_gitlab_state_list)

    if [ "${#releases[@]}" -eq 1 ]; then
        echo "${releases[0]}"
    else
        echo "gitlab"
    fi
}
