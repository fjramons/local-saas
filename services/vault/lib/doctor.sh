# --- 'saas vault doctor [--fix]': diagnose-only by default, same convention as
# services/gitlab/lib/doctor.sh ('brew doctor'/'npm audit'-style, never mutates without --fix).
# Split into pure _check_* (unit-testable) and _fix_* (only ever called with --fix) function pairs.

# _saas_vault_doctor_check_pods NAMESPACE
# Prints one line per pod stuck in the 'Unknown' phase (node unreachable, kubelet down, etc.).
_saas_vault_doctor_check_pods() {
    local ns="$1"
    kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 == "Unknown" {print $1}'
}

_saas_vault_doctor_fix_pods() {
    local ns="$1"
    local pod
    while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        _saas_log_step "Force-deleting stuck pod '$pod'…"
        kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1
    done < <(_saas_vault_doctor_check_pods "$ns")
}

# _saas_vault_doctor_check_sealed NAMESPACE RELEASE
# Prints "sealed" if the instance reports sealed, "unreachable" if 'bao status' couldn't run, nothing if fine.
_saas_vault_doctor_check_sealed() {
    local ns="$1" release="$2"
    local result
    result="$(_saas_vault_verify_status "$ns" "$release" 2>/dev/null)" || { echo "unreachable"; return 0; }
    case "$result" in
        *sealed=true*) echo "sealed" ;;
    esac
}

# _saas_vault_doctor_check_certificate NAMESPACE NAME
# Prints "not-ready" if the named Certificate isn't Ready, nothing if it is (or doesn't exist, not this check's job).
_saas_vault_doctor_check_certificate() {
    local ns="$1" name="$2"
    kubectl -n "$ns" get certificate "$name" >/dev/null 2>&1 || return 0
    local ready
    ready="$(kubectl -n "$ns" get certificate "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [ "$ready" = "True" ] || echo "not-ready"
}

# _saas_vault_doctor_check_unseal_drift NAMESPACE RELEASE THRESHOLD
# Prints "drifted" if the in-cluster unseal-keys Secret doesn't match the local saved keys file
# (e.g. the Secret was deleted, or a stale threshold from a prior --key-threshold value).
_saas_vault_doctor_check_unseal_drift() {
    local ns="$1" release="$2" threshold="$3"
    local secret_name="${release}-vault-unseal-keys"
    _saas_vault_secrets_load "$release" || { echo "drifted"; return 0; }

    local i live_key saved_key
    for i in $(seq 1 "$threshold"); do
        live_key="$(kubectl -n "$ns" get secret "$secret_name" -o jsonpath="{.data.key${i}}" 2>/dev/null | base64 -d 2>/dev/null)"
        saved_key="$(_saas_vault_secrets_share_at "$i" "$SAAS_VAULT_KEYS_SHARES_CSV")"
        [ "$live_key" = "$saved_key" ] || { echo "drifted"; return 0; }
    done
}

_saas_vault_doctor_help() {
    cat <<'EOF'
Usage: saas vault doctor [RELEASE] [OPTIONS]

Diagnoses (and, with --fix, repairs) a broken install: pods stuck
Unknown, the external or internal TLS Certificate not Ready, the
instance unexpectedly sealed, and the in-cluster unseal-keys Secret
drifted from the locally saved key shares.

Options:
      --fix     Repair whatever was found (never runs without this flag)
  -h, --help    Show this help
EOF
}

_saas_vault_doctor() {
    local fix=false
    local args
    args=$(getopt -o h -l fix,help --name saas_vault_doctor -- "$@") || { _saas_vault_doctor_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --fix) fix=true; shift ;;
            -h|--help) _saas_vault_doctor_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    local ns="$SAAS_VAULT_STATE_NAMESPACE"
    local found_issue=false

    local -a stuck_pods=()
    while IFS= read -r p; do [ -n "$p" ] && stuck_pods+=("$p"); done < <(_saas_vault_doctor_check_pods "$ns")
    if [ "${#stuck_pods[@]}" -gt 0 ]; then
        found_issue=true
        _saas_log_warn "Pod(s) stuck in 'Unknown' phase: ${stuck_pods[*]}"
        $fix && _saas_vault_doctor_fix_pods "$ns"
    fi

    if [ "$(_saas_vault_doctor_check_certificate "$ns" "${release}-vault-cert")" = "not-ready" ]; then
        found_issue=true
        _saas_log_warn "External TLS Certificate '${release}-vault-cert' is not Ready."
    fi
    if [ "$(_saas_vault_doctor_check_certificate "$ns" "${release}-vault-int-cert")" = "not-ready" ]; then
        found_issue=true
        _saas_log_warn "Internal TLS Certificate '${release}-vault-int-cert' is not Ready."
    fi

    local sealed_check
    sealed_check="$(_saas_vault_doctor_check_sealed "$ns" "$release")"
    case "$sealed_check" in
        sealed)
            found_issue=true
            _saas_log_warn "Vault is sealed."
            if $fix; then
                _saas_log_step "Re-applying unseal keys…"
                _saas_vault_unseal_secret_apply "$release" "$ns" "$SAAS_VAULT_STATE_KEY_THRESHOLD"
                _saas_vault_wait_unsealed "$release" "$ns"
            fi
            ;;
        unreachable)
            found_issue=true
            _saas_log_warn "Could not reach Vault's pod to check its seal status."
            ;;
    esac

    if [ "$(_saas_vault_doctor_check_unseal_drift "$ns" "$release" "$SAAS_VAULT_STATE_KEY_THRESHOLD")" = "drifted" ]; then
        found_issue=true
        _saas_log_warn "The in-cluster unseal-keys Secret doesn't match the saved key shares."
        $fix && _saas_vault_unseal_secret_apply "$release" "$ns" "$SAAS_VAULT_STATE_KEY_THRESHOLD"
    fi

    if ! $found_issue; then
        _saas_log_ok "No issues found."
    elif ! $fix; then
        _saas_log_info "Re-run with --fix to repair the issues above."
    fi
}
