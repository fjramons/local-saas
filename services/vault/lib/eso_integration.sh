# --- 'saas vault integrate eso': generic, gitlab-agnostic counterpart of gitlab_integration.sh,
# for wiring this Vault release up as a secrets backend for ANY External Secrets Operator
# installation, in any cluster. Unlike the gitlab integration, there's no "saas <target> integrate
# vault" counterpart to apply the reviewer manifest automatically (no such service exists in
# general), so that one step is documented as a plain 'kubectl apply' instead. Same order-
# independence guarantee: never mutates the target cluster, never mutates Vault before the
# target is confirmed reachable and the reviewer token is confirmed present.

_saas_vault_integrate_eso_help() {
    cat <<'EOF'
Usage: saas vault integrate eso [OPTIONS]

Wires this Vault release up as a secrets backend for an External
Secrets Operator (ESO) installation running ANYWHERE (any cluster this
kubeconfig has a context for), seeding one placeholder KV entry purely
to prove the wiring works end to end. ESO itself is never installed by
this tool.

Same two-phase, safely re-runnable design as 'saas vault integrate
gitlab' (see its --help for the full explanation), except applying the
generated reviewer manifest is a plain 'kubectl apply' here (there's no
"saas <target> integrate vault" counterpart for an arbitrary target).

Options:
      --vault-release NAME       This Vault release (default:
                                  suggested if only one exists)
      --target-context NAME          Kubeconfig context of the cluster
                                  ESO runs in (required)
      --target-namespace NS           Namespace ESO/the SecretStore live
                                  in (default: external-secrets)
      --target-serviceaccount NAME     ESO's ServiceAccount name
                                  (default: external-secrets)
      --output-dir DIR                  Where to write generated
                                  manifests (default: see below)
  -y, --yes                            Don't ask for anything extra
  -h, --help                           Show this help

Default --output-dir:
  ~/.local/state/saas/vault/<vault-release>/eso-integration/<target-context>/

Examples:
  saas vault integrate eso --target-context kind-my-cluster
EOF
}

_saas_vault_integrate_eso() {
    local vault_release="" target_context="" target_namespace="external-secrets"
    local target_serviceaccount="external-secrets" output_dir="" yes=false

    local args
    args=$(getopt -o yh -l vault-release:,target-context:,target-namespace:,target-serviceaccount:,output-dir:,yes,help --name saas_vault_integrate_eso -- "$@") || {
        _saas_vault_integrate_eso_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --vault-release)       vault_release="$2"; shift 2 ;;
            --target-context)        target_context="$2"; shift 2 ;;
            --target-namespace)      target_namespace="$2"; shift 2 ;;
            --target-serviceaccount) target_serviceaccount="$2"; shift 2 ;;
            --output-dir)            output_dir="$2"; shift 2 ;;
            -y|--yes)                yes=true; shift ;;
            -h|--help)               _saas_vault_integrate_eso_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$vault_release" ] || vault_release="$(_saas_vault_suggest_release)"
    [ -n "$target_context" ] || { _saas_log_err "--target-context is required."; return 1; }

    # --- Phase A, step 1: confirm THIS Vault release is up and unsealed ---
    _saas_vault_state_load "$vault_release" || { _saas_log_err "No saved state for Vault release '$vault_release'."; return 1; }
    local ob_ns="$SAAS_VAULT_STATE_NAMESPACE"
    local live_status
    live_status="$(_saas_vault_verify_status "$ob_ns" "$vault_release" 2>/dev/null)"
    case "$live_status" in
        *sealed=false*) : ;;
        *) _saas_log_err "Vault release '$vault_release' is not reachable/unsealed. Nothing else will run."; return 1 ;;
    esac

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/vault/${vault_release}/eso-integration/${target_context}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    # --- Phase A, step 2: is the target cluster reachable at all? ---
    if ! _saas_vault_target_reachable "$target_context"; then
        _saas_log_err "Could not reach the target cluster (context '$target_context')."
        _saas_log_err "Nothing on the Vault side has been touched. Make sure the context is valid, then re-run."
        return 1
    fi

    # --- Phase A, step 3: does the reviewer ServiceAccount/token already exist there? ---
    if ! _saas_vault_target_reviewer_secret_exists "$target_context" "$vault_release"; then
        local reviewer_manifest="$output_dir/reviewer-serviceaccount.yaml"
        _saas_vault_render_integration_manifest \
            "$_SAAS_VAULT_DIR/values/gitlab-reviewer-serviceaccount.yaml.tpl" "$reviewer_manifest" \
            "SAAS_VAULT_RELEASE=$vault_release"
        _saas_log_warn "The reviewer ServiceAccount doesn't exist yet in the target cluster."
        _saas_log_info "Manifest written to: $reviewer_manifest"
        _saas_log_info "Apply it with: kubectl --context $target_context apply -f $reviewer_manifest"
        _saas_log_info "Then re-run this same command to continue (nothing on Vault has been touched yet)."
        return 1
    fi

    # --- Phase B: Vault-side mutation only, from here on ---
    _saas_log_step "Reading the reviewer token from the target cluster (read-only)…"
    local reviewer_token reviewer_ca_b64 k8s_host
    reviewer_token="$(_saas_vault_target_reviewer_token "$target_context" "$vault_release")"
    reviewer_ca_b64="$(_saas_vault_target_reviewer_ca "$target_context" "$vault_release")"
    k8s_host="$(_saas_vault_target_api_server "$target_context")"
    if [ -z "$reviewer_token" ] || [ -z "$k8s_host" ]; then
        _saas_log_err "Could not read the reviewer token or API server address from context '$target_context'."
        return 1
    fi
    local reviewer_ca_pem
    reviewer_ca_pem="$(echo "$reviewer_ca_b64" | base64 -d 2>/dev/null)"

    local kv_path="eso-demo"
    local role_name="${vault_release}-eso-demo-role"
    local policy_name="${vault_release}-eso-demo-policy"

    _saas_vault_kv_engine_ensure "$vault_release" "$ob_ns" "$kv_path" || return 1
    _saas_vault_k8s_auth_ensure "$vault_release" "$ob_ns" || return 1
    _saas_vault_k8s_auth_configure "$vault_release" "$ob_ns" "$k8s_host" "$reviewer_ca_pem" "$reviewer_token" || return 1
    _saas_vault_policy_write "$vault_release" "$ob_ns" "$policy_name" "path \"${kv_path}/*\" { capabilities = [\"read\"] }" || return 1
    _saas_vault_k8s_role_write "$vault_release" "$ob_ns" "$role_name" "$target_serviceaccount" "$target_namespace" "$policy_name" || return 1

    _saas_log_step "Seeding one placeholder KV entry ('$kv_path')…"
    _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" eso-demo "example=hello from Vault"

    _saas_log_step "Rendering SecretStore/ExternalSecret manifests…"
    local ca_bundle_b64
    ca_bundle_b64="$(_saas_vault_ca_bundle_b64 "$ob_ns" "$vault_release")"
    local -a common_vars=(
        "SAAS_VAULT_RELEASE=$vault_release"
        "SAAS_VAULT_URL=https://${SAAS_VAULT_STATE_DOMAIN}"
        "SAAS_VAULT_CA_BUNDLE_B64=$ca_bundle_b64"
        "SAAS_TARGET_NAMESPACE=$target_namespace"
        "SAAS_TARGET_SERVICEACCOUNT=$target_serviceaccount"
    )
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/eso-secretstore.yaml.tpl" "$output_dir/eso-secretstore.yaml" "${common_vars[@]}"
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/eso-externalsecret-example.yaml.tpl" "$output_dir/eso-externalsecret-example.yaml" "${common_vars[@]}"

    _saas_log_ok "Vault is ready to serve secrets to ESO at context '$target_context'."
    _saas_log_info "Apply the generated manifests there with:"
    _saas_log_info "  kubectl --context $target_context apply -f $output_dir/eso-secretstore.yaml -f $output_dir/eso-externalsecret-example.yaml"
}
