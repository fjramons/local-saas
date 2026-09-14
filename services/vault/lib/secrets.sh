# --- Break-glass secret material for 'saas vault': the root token and every Shamir unseal key
# share produced by 'bao operator init'. Deliberately kept in its own file, separate from
# state.sh's install parameters, and chmod 600: anyone who can read this file can unseal the
# instance (master-key-equivalent access) and authenticate as root. Never printed anywhere except
# through 'saas vault credentials --reveal-root-token/--reveal-unseal-keys', and never written to
# any Kubernetes object in-cluster (see init.sh: only a threshold-sized subset of the key shares,
# never the root token, ever makes it into the in-cluster 'unseal-keys' Secret, and always sourced
# FROM this file, never generated independently in-cluster).

_saas_vault_secrets_dir() {
    echo "${SAAS_VAULT_STATE_DIR:-$HOME/.local/state/saas/vault}"
}

_saas_vault_secrets_path() {
    local release="$1"
    echo "$(_saas_vault_secrets_dir)/${release}.keys.env"
}

# _saas_vault_secrets_save RELEASE ROOT_TOKEN KEY_SHARES_CSV
# KEY_SHARES_CSV: every unseal key share, comma-separated, in the order 'bao operator init' returned them.
_saas_vault_secrets_save() {
    local release="$1" root_token="$2" key_shares_csv="$3"
    local dir path
    dir="$(_saas_vault_secrets_dir)"
    path="$(_saas_vault_secrets_path "$release")"
    mkdir -p "$dir" || { _saas_log_err "Could not create $dir"; return 1; }

    local tmp="${path}.tmp.$$"
    : > "$tmp"
    chmod 600 "$tmp"
    printf 'SAAS_VAULT_KEYS_ROOT_TOKEN=%q\n' "$root_token" >> "$tmp"
    printf 'SAAS_VAULT_KEYS_SHARES_CSV=%q\n' "$key_shares_csv" >> "$tmp"
    mv "$tmp" "$path"
    chmod 600 "$path"
}

# _saas_vault_secrets_load RELEASE
# Sources the keys file if it exists (SAAS_VAULT_KEYS_* variables); returns 1 silently if absent.
_saas_vault_secrets_load() {
    local release="$1"
    local path
    path="$(_saas_vault_secrets_path "$release")"
    [ -f "$path" ] || return 1
    # shellcheck disable=SC1090
    source "$path"
}

_saas_vault_secrets_exists() {
    local release="$1"
    [ -f "$(_saas_vault_secrets_path "$release")" ]
}

_saas_vault_secrets_delete() {
    local release="$1"
    rm -f "$(_saas_vault_secrets_path "$release")"
}

# _saas_vault_secrets_share_at INDEX CSV
# 1-indexed. Used to pull "the first N shares" (N = key threshold) out of the saved CSV for the
# in-cluster unseal-keys Secret, without ever writing the full share count (or the root token)
# in-cluster.
_saas_vault_secrets_share_at() {
    local index="$1" csv="$2"
    echo "$csv" | cut -d',' -f"$index"
}

_saas_vault_secrets_share_count() {
    local csv="$1"
    [ -z "$csv" ] && { echo 0; return; }
    echo "$csv" | awk -F',' '{print NF}'
}
