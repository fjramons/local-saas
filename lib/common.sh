# --- Helpers shared by every service in saas.sh
# Same idiom as kind_cluster (bash-aliases/.bash_aliases.d/local-cluster-functions.sh): getopt for flags, prompts with a bracketed default / numbered menu for enums, explicit confirmation for destructive actions, logging with semantic emoji, no 'set -e'.

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
