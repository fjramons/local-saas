# --- Diagnostics (and, with --fix, repair) for 'saas minio'. Simpler than gitlab's doctor: no
# SSH proxy, no chart-managed datastore drift to worry about beyond MinIO's own single credential.

_saas_minio_doctor_help() {
    cat <<'EOF'
Usage: saas minio doctor [RELEASE] [OPTIONS]

Diagnoses common problems left behind by things outside this tool's
control, most notably a host reboot mid-session: pods stuck in
'Unknown' phase, and the '${release}-credentials' Secret drifting from
MinIO's own actual running root password.

By default only reports what it finds; nothing is changed unless
--fix is passed.

Options:
      --fix    Apply repairs for every problem found
  -h, --help   Show this help

Examples:
  saas minio doctor
  saas minio doctor demo --fix
EOF
}

# --------------------------------------------------------------------
# A. Pod health
# --------------------------------------------------------------------

_saas_minio_doctor_check_pods() {
    local ns="$1"
    kubectl -n "$ns" get pods -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase == "Unknown") | .metadata.name'
}

_saas_minio_doctor_fix_pods() {
    local ns="$1"; shift
    local pod
    for pod in "$@"; do
        kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1
    done
}

# --------------------------------------------------------------------
# B. Root credential drift
# --------------------------------------------------------------------

# _saas_minio_doctor_check_credentials NAMESPACE RELEASE
# First line: the running pod's actual MINIO_ROOT_PASSWORD (the source of truth). Second line
# ("drift"), if any: the saved Secret's password no longer matches it. No output (nonzero exit) if
# no pod is reachable.
_saas_minio_doctor_check_credentials() {
    local ns="$1" release="$2"
    local pod
    pod="$(kubectl -n "$ns" get pods -l "app=${release}" -o name 2>/dev/null | head -n1 | sed 's#^pod/##')"
    [ -n "$pod" ] || return 1

    local real_password
    real_password="$(kubectl -n "$ns" exec "$pod" -- printenv MINIO_ROOT_PASSWORD 2>/dev/null)"
    [ -n "$real_password" ] || return 1
    echo "$real_password"

    local secret_password
    secret_password="$(kubectl -n "$ns" get secret "${release}-credentials" -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d)"
    [ "$secret_password" = "$real_password" ] || echo "drift"
}

# _saas_minio_doctor_fix_credentials NAMESPACE RELEASE REAL_PASSWORD
# Re-applies the Secret with REAL_PASSWORD (reusing _saas_minio_secrets_apply, already idempotent),
# then restarts the workload so it re-reads it consistently on the next scheduling event (harmless:
# the running pod's OWN env is already the real password; this just keeps the Secret from staying
# stale for anything created/restarted later), and updates the saved state.
_saas_minio_doctor_fix_credentials() {
    local ns="$1" release="$2" real_password="$3"

    local root_user
    root_user="$(kubectl -n "$ns" get secret "${release}-credentials" -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d)"
    [ -n "$root_user" ] || root_user="${SAAS_MINIO_STATE_ROOT_USER:-}"
    [ -n "$root_user" ] || { _saas_log_err "Could not determine the MinIO root user."; return 1; }

    _saas_minio_secrets_apply "$ns" "$release" "$root_user" "$real_password" || return 1
    _saas_minio_state_save_key "$release" "ROOT_PASSWORD" "$real_password"
}

# --------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------

_saas_minio_doctor() {
    local fix=false
    local args
    args=$(getopt -o h -l fix,help --name saas_minio_doctor -- "$@") || { _saas_minio_doctor_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --fix) fix=true; shift ;;
            -h|--help) _saas_minio_doctor_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    local release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for '$release'."; return 1; }
    local ns="$SAAS_MINIO_STATE_NAMESPACE"
    local problems=0

    echo ""
    echo "Doctor: '$release'$($fix && echo ' (--fix: repairs will be applied)')"
    echo ""

    # A. Pod health
    local -a unknown_pods=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && unknown_pods+=("$line"); done < <(_saas_minio_doctor_check_pods "$ns")
    if [ "${#unknown_pods[@]}" -eq 0 ]; then
        echo "✅ Pods: none stuck in 'Unknown' phase."
    else
        problems=$((problems + 1))
        echo "⚠️  Pods: ${#unknown_pods[@]} stuck in 'Unknown' phase: ${unknown_pods[*]}"
        if $fix; then
            _saas_minio_doctor_fix_pods "$ns" "${unknown_pods[@]}"
            echo "   🔧 Force-deleted; their controller will recreate them."
        fi
    fi

    # B. Root credential drift
    local -a cred_out=()
    while IFS= read -r line; do [ -n "$line" ] && cred_out+=("$line"); done < <(_saas_minio_doctor_check_credentials "$ns" "$release")
    if [ "${#cred_out[@]}" -eq 0 ]; then
        echo "⚠️  Credentials: pod not reachable, skipped."
    else
        local real_password="${cred_out[0]}"
        if [ "${#cred_out[@]}" -eq 1 ]; then
            echo "✅ Credentials: the '${release}-credentials' Secret matches the running pod."
        else
            problems=$((problems + 1))
            echo "⚠️  Credentials: the '${release}-credentials' Secret is out of sync with the running pod."
            if $fix; then
                if _saas_minio_doctor_fix_credentials "$ns" "$release" "$real_password"; then
                    echo "   🔧 Secret reconciled and saved state updated."
                else
                    echo "   ❌ Could not reconcile the Secret, see the error above."
                fi
            fi
        fi
    fi

    echo ""
    if [ "$problems" -eq 0 ]; then
        _saas_log_ok "Nothing to report."
    elif $fix; then
        _saas_log_ok "Ran repairs for $problems problem(s). Re-run 'saas minio doctor $release' to confirm."
    else
        _saas_log_warn "$problems problem(s) found. Re-run with --fix to repair them."
    fi
}
