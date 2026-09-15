# --- Helpers shared by every service in saas.sh
# Same idiom as kind_cluster (bash-aliases/.bash_aliases.d/local-cluster-functions.sh): getopt for flags, prompts with a bracketed default / numbered menu for enums, explicit confirmation for destructive actions, logging with semantic emoji, no 'set -e'.

# MinIO/mc image pins, shared by services/gitlab/lib/datastore.sh (GitLab's own private MinIO) and
# services/minio/lib/*.sh (the standalone service): promoted here the moment a second consumer
# needed the exact same tags with zero variation, same threshold already used below for
# _saas_require_kind_cluster_fn/_saas_ensure_certmanager/_saas_resolve_storage_class. Originally
# pulled from Docker Hub's minio/minio, moved to quay.io/minio/minio (same tags) after MinIO removed
# that entire Docker Hub repository (community edition is now source-only); re-verify quay.io
# directly ('docker pull quay.io/minio/IMAGE:TAG') before bumping, not Docker Hub/helm search.
_SAAS_MINIO_IMAGE="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
_SAAS_MC_IMAGE="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"

_saas_log_info() { echo "ℹ️  $*" >&2; }
_saas_log_ok()   { echo "✅ $*" >&2; }
_saas_log_warn() { echo "⚠️  $*" >&2; }
_saas_log_err()  { echo "❌ $*" >&2; }
_saas_log_step() { echo "🚀 $*" >&2; }
_saas_log_wait() { echo "⏳ $*" >&2; }

# _saas_check_deps CMD1 CMD2 ...
# Checks that the required external commands are on the PATH; prints all the missing ones at once instead of aborting on the first.
_saas_check_deps() {
    local -a missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        _saas_log_err "Missing dependencies: ${missing[*]}"
        return 1
    fi
}

# _saas_prompt LABEL DEFAULT NON_INTERACTIVE
# Prints the resolved value on stdout (to capture with $(...)); the prompt and the non-interactive-mode notice go to stderr so they don't pollute the capture. Same contract as _kind_cluster_prompt.
_saas_prompt() {
    local label="$1" default="$2" non_interactive="$3"
    local value

    if $non_interactive || [ ! -t 0 ]; then
        _saas_log_info "Using default for '$label': $default (non-interactive mode)"
        printf '%s' "$default"
        return 0
    fi

    printf '%s [%s]: ' "$label" "$default" >&2
    read -r value
    printf '%s' "${value:-$default}"
}

# _saas_prompt_bool LABEL DEFAULT(true/false) NON_INTERACTIVE
_saas_prompt_bool() {
    local label="$1" default="$2" non_interactive="$3"
    local hint="y/N" value
    [ "$default" = true ] && hint="Y/n"

    if $non_interactive || [ ! -t 0 ]; then
        _saas_log_info "Using default for '$label': $default (non-interactive mode)"
        printf '%s' "$default"
        return 0
    fi

    printf '%s [%s]: ' "$label" "$hint" >&2
    read -r value
    case "$value" in
        "") printf '%s' "$default" ;;
        y|Y|yes|Yes|YES) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

# _saas_prompt_validated LABEL DEFAULT NON_INTERACTIVE ERROR_MSG VALIDATOR_FN
# Re-asks (up to 5 attempts) if the value doesn't pass VALIDATOR_FN "$value". Without a tty/in non-interactive mode there's no loop possible: if DEFAULT itself isn't valid, it aborts.
_saas_prompt_validated() {
    local label="$1" default="$2" non_interactive="$3" error_msg="$4" validator="$5"
    local value attempt

    for attempt in 1 2 3 4 5; do
        value="$(_saas_prompt "$label" "$default" "$non_interactive")"
        "$validator" "$value" && { printf '%s' "$value"; return 0; }

        _saas_log_err "$error_msg (got: '$value')"
        { $non_interactive || [ ! -t 0 ]; } && return 1
    done
    return 1
}

# _saas_prompt_menu LABEL DEFAULT NON_INTERACTIVE OPTION1 OPTION2 ...
# DEFAULT is always listed as "0) ... (default)"; the rest are numbered 1, 2... Returns the text of the chosen option, not the number.
_saas_prompt_menu() {
    local label="$1" default="$2" non_interactive="$3"
    shift 3
    local -a options=("$@")

    if $non_interactive || [ ! -t 0 ]; then
        _saas_log_info "Using default for '$label': $default (non-interactive mode)"
        printf '%s' "$default"
        return 0
    fi

    local -a rest=()
    local opt
    for opt in "${options[@]}"; do
        [ "$opt" != "$default" ] && rest+=("$opt")
    done

    echo "$label:" >&2
    printf '  0) %s (default)\n' "$default" >&2
    local i
    for i in "${!rest[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${rest[$i]}" >&2
    done

    local choice attempt
    for attempt in 1 2 3 4 5; do
        printf 'Pick a number [0]: ' >&2
        read -r choice
        [ -z "$choice" ] && choice=0
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -eq 0 ]; then
                printf '%s' "$default"; return 0
            elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#rest[@]}" ]; then
                printf '%s' "${rest[$((choice - 1))]}"
                return 0
            fi
        fi
        _saas_log_err "Invalid option, pick a number between 0 and ${#rest[@]}."
    done
    return 1
}

# _saas_confirm YES_FLAG
# Destructive confirmation: only skipped with an explicit -y/--yes; without a tty and without -y, it aborts (never assumes consent).
_saas_confirm() {
    local yes="$1"

    $yes && return 0

    if [ ! -t 0 ]; then
        _saas_log_err "Confirmation is required but there's no interactive terminal. Use -y/--yes."
        return 1
    fi

    local confirm
    printf "Continue? [y/N] " >&2
    read -r confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        return 0
    fi
    echo "⛔ Operation cancelled." >&2
    return 1
}

# _saas_random_password [LENGTH]
_saas_random_password() {
    local len="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len"
}

# --- Helpers below are shared by every service that manages its own kind cluster and/or
# cert-manager-issued TLS. They started out as gitlab-only code, but a second service (openbao)
# needs the exact same logic with zero variation, which is the point at which sharing them stops
# being premature: the interface is already proven, not guessed at. Service-specific operators
# (e.g. gitlab's CloudNativePG/redis-operator/DuckDNS-webhook installs) stay in their own service,
# since those genuinely differ per service; these three don't.

# --- Cluster backend selection, shared by every service's own lib/cluster.sh (create/delete/use/
# exists) and by gitlab's ssh.sh (expose add/remove). By default this repo manages its own kind
# clusters via 'saas cluster' (services/cluster/), which is self-contained: no external dependency.
# Setting USE_KIND_CLUSTER_FUNCTION=true switches every one of these back to the legacy
# 'kind_cluster' function instead (maintained separately, in a sibling repo, referenced here only by
# function name, never by this PC's absolute path), for a transition period. Since both create the
# exact same kind of real kind cluster with no saas-managed inventory of their own, clusters created
# by one are already visible to and manageable by the other (see CLAUDE.md's Design notes).

_saas_cluster_backend_is_legacy() { [ "${USE_KIND_CLUSTER_FUNCTION:-false}" = "true" ]; }

# _saas_require_cluster_backend
# Only the legacy backend has an external dependency to check: 'saas cluster' is always available,
# it's part of this repo and already sourced by saas.sh.
_saas_require_cluster_backend() {
    _saas_cluster_backend_is_legacy || return 0
    if ! command -v kind_cluster >/dev/null 2>&1; then
        _saas_log_err "USE_KIND_CLUSTER_FUNCTION=true, but the 'kind_cluster' function is not loaded in this shell."
        _saas_log_err "--cluster-mode kind needs it to create/manage the local cluster."
        _saas_log_err "Load 'local-cluster-functions.sh' from the bash-aliases repo before continuing, or unset USE_KIND_CLUSTER_FUNCTION to use this repo's own 'saas cluster' instead."
        return 1
    fi
}

# _saas_cluster_backend_create KIND_NAME WORKERS STORAGE_MODE NON_INTERACTIVE YES
_saas_cluster_backend_create() {
    local kind_name="$1" workers="$2" storage_mode="$3" non_interactive="$4" yes="$5"
    _saas_require_cluster_backend || return 1

    local -a args=(create --name "$kind_name" --workers "$workers" \
        --storage-mode "$storage_mode" --expose-mode ingress-nginx)
    $non_interactive && args+=(--non-interactive)
    $yes && args+=(--yes)

    _saas_log_step "Creating kind cluster '$kind_name' (workers=$workers, storage-mode=$storage_mode)…"
    if _saas_cluster_backend_is_legacy; then
        kind_cluster "${args[@]}"
    else
        saas cluster "${args[@]}"
    fi
}

# _saas_cluster_backend_delete KIND_NAME PURGE_STORAGE
_saas_cluster_backend_delete() {
    local kind_name="$1" purge="$2"
    _saas_require_cluster_backend || return 1

    local -a args=(delete "$kind_name" --yes)
    $purge && args+=(--purge-storage)

    _saas_log_step "Deleting kind cluster '$kind_name'$($purge && echo ' (with --purge-storage)')…"
    if _saas_cluster_backend_is_legacy; then
        kind_cluster "${args[@]}"
    else
        saas cluster "${args[@]}"
    fi
}

# _saas_cluster_backend_use KIND_NAME
# Points kubectl at the given kind cluster's context.
_saas_cluster_backend_use() {
    local kind_name="$1"
    _saas_require_cluster_backend || return 1
    if _saas_cluster_backend_is_legacy; then
        kind_cluster use "$kind_name" >/dev/null
    else
        saas cluster use "$kind_name" >/dev/null
    fi
}

_saas_cluster_backend_exists() {
    local kind_name="$1"
    _saas_require_cluster_backend || return 1
    kind get clusters -q 2>/dev/null | grep -qx "$kind_name"
}

# _saas_cluster_backend_expose_add ARGS...
_saas_cluster_backend_expose_add() {
    _saas_require_cluster_backend || return 1
    if _saas_cluster_backend_is_legacy; then
        kind_cluster expose add "$@"
    else
        saas cluster expose add "$@"
    fi
}

# _saas_cluster_backend_expose_remove ARGS...
_saas_cluster_backend_expose_remove() {
    _saas_require_cluster_backend || return 1
    if _saas_cluster_backend_is_legacy; then
        kind_cluster expose remove "$@"
    else
        saas cluster expose remove "$@"
    fi
}

# _saas_resolve_storage_class [EXPLICIT] NON_INTERACTIVE
# Resolves the StorageClass to use in --cluster-mode existing. Never fails over a resolvable ambiguity in non-interactive mode ("sensible defaults even without interactivity"); only fails if the cluster has no StorageClass at all.
_saas_resolve_storage_class() {
    local explicit="$1" non_interactive="$2"

    if [ -n "$explicit" ]; then
        printf '%s' "$explicit"
        return 0
    fi

    local -a classes=()
    local default_class=""
    local line name is_default
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line%% *}"
        is_default="${line#* }"
        classes+=("$name")
        [ "$is_default" = "true" ] && default_class="$name"
    done < <(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null)

    if [ "${#classes[@]}" -eq 0 ]; then
        _saas_log_err "The existing cluster has no StorageClass at all, there's no reasonable choice to make."
        _saas_log_err "Create one (or pass one with --storage-class NAME) before installing."
        return 1
    fi

    if [ -n "$default_class" ]; then
        printf '%s' "$default_class"
        return 0
    fi

    if [ "${#classes[@]}" -eq 1 ]; then
        printf '%s' "${classes[0]}"
        return 0
    fi

    local -a sorted_classes=()
    while IFS= read -r line; do
        sorted_classes+=("$line")
    done < <(printf '%s\n' "${classes[@]}" | sort)

    if $non_interactive || [ ! -t 0 ]; then
        local chosen="${sorted_classes[0]}"
        _saas_log_warn "Multiple StorageClasses and none marked default; picking '$chosen' (first alphabetically)."
        _saas_log_warn "Pin one explicitly with --storage-class NAME to not depend on this automatic choice."
        printf '%s' "$chosen"
        return 0
    fi

    _saas_prompt_menu "StorageClass to use" "${sorted_classes[0]}" false "${classes[@]}"
}

_SAAS_CERTMANAGER_VERSION_HINT="see 'helm search repo jetstack/cert-manager --versions' (always latest stable, not pinned)"

# _saas_ensure_certmanager
# Idempotent: does nothing if cert-manager is already installed (CRDs present).
_saas_ensure_certmanager() {
    if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        _saas_log_info "cert-manager is already installed."
        return 0
    fi

    _saas_log_step "Installing cert-manager…"
    if ! helm repo list -o json 2>/dev/null | jq -e '.[]? | select(.name == "jetstack")' >/dev/null; then
        helm repo add jetstack https://charts.jetstack.io >/dev/null || return 1
    fi
    helm repo update jetstack >/dev/null || return 1

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true --wait --timeout 180s
}
