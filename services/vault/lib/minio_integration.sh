# --- 'saas vault integrate minio': wires this Vault release up as a secrets backend for a MinIO
# instance managed by 'saas minio' (possibly in a different cluster), for External Secrets
# Operator to consume. See services/minio/lib/vault_integration.sh for the symmetric 'saas minio
# integrate vault' counterpart that applies the manifests generated here INTO the MinIO cluster:
# this file never mutates any cluster except Vault's own, by design (see CLAUDE.md). Direct
# structural copy of gitlab_integration.sh's two-phase design, reusing every generic helper in
# integration_common.sh unchanged.

_saas_vault_integrate_minio_help() {
    cat <<'EOF'
Usage: saas vault integrate minio [OPTIONS]

Wires this Vault release up as a secrets backend for a MinIO instance
managed by 'saas minio', so External Secrets Operator (ESO) running in
the MinIO cluster can sync (and, when rotated in Vault, actually
update) MinIO's root credentials.

Two-phase, safely re-runnable at any point, and mutates ONLY this
Vault release, never the MinIO cluster:

  Phase A (read-only preflight): confirms this Vault release is up
  and unsealed, resolves the target MinIO cluster's kubeconfig
  context, and checks it's reachable. If a reviewer ServiceAccount/
  token isn't present there yet, a manifest is generated for
  'saas minio integrate vault' to apply, and this command exits
  non-zero with NO Vault-side change at all.

  Phase B (Vault-side mutation): once the reviewer token is confirmed
  present, enables a KV v2 engine and Kubernetes auth trusting the
  MinIO cluster, creates a scoped policy/role, seeds MinIO's real root
  credentials, and generates the SecretStore/ExternalSecret manifests
  for 'saas minio integrate vault' to apply there.

Running this before 'saas minio' even exists yet is safe: phase A's
preflight fails cleanly with an actionable message, nothing on the
Vault side is ever touched.

Options:
      --vault-release NAME     This Vault release (default:
                                suggested if only one exists)
      --minio-release NAME        A 'saas minio' release to read
                                connection info from (kubeconfig
                                context/namespace); either this or
                                --minio-context is required
      --minio-context NAME         Kubeconfig context of the target
                                MinIO cluster (overrides what
                                --minio-release would suggest)
      --minio-namespace NS         MinIO's namespace (default: read
                                from --minio-release's saved state, or
                                required with --minio-context alone)
      --eso-namespace NS            Namespace ESO runs in, in the
                                MinIO cluster (default: external-secrets)
      --eso-serviceaccount NAME     ESO's ServiceAccount name (default:
                                external-secrets)
      --output-dir DIR               Where to write generated manifests
                                (default: see below)
      --no-seed                      Don't seed MinIO's live root
                                credentials into Vault (phase B still
                                runs, with placeholder values instead)
  -y, --yes                         Don't ask for anything extra
  -h, --help                        Show this help

Default --output-dir:
  ~/.local/state/saas/vault/<vault-release>/minio-integration/<minio-release-or-context>/

Examples:
  saas vault integrate minio --minio-release minio
  saas vault integrate minio --minio-context kind-minio --minio-namespace minio
EOF
}

# _saas_vault_minio_seed_secrets VAULT_RELEASE VAULT_NAMESPACE KV_PATH MINIO_CONTEXT MINIO_NAMESPACE MINIO_RELEASE
# Best-effort: reads minio's OWN live '<release>-credentials' Secret (read-only) and re-writes it
# into Vault's KV path under the exact same field names services/minio/lib/backend.sh's
# _saas_minio_secrets_apply already uses (rootUser/rootPassword) - the same field names GitLab's
# own minio Secret already uses too, so nothing needs translation anywhere.
_saas_vault_minio_seed_secrets() {
    local vault_release="$1" ob_ns="$2" kv_path="$3" minio_context="$4" minio_ns="$5" minio_release="$6"

    local root_user root_password
    root_user="$(kubectl --context "$minio_context" -n "$minio_ns" get secret "${minio_release}-credentials" -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d 2>/dev/null)"
    root_password="$(kubectl --context "$minio_context" -n "$minio_ns" get secret "${minio_release}-credentials" -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$root_user" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" minio "rootUser=$root_user" "rootPassword=$root_password"
    else
        _saas_log_warn "Could not read minio's live credentials secret ('${minio_release}-credentials' in '$minio_ns'); seeding a placeholder."
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" minio "rootUser=minio-root" "rootPassword=CHANGE-ME"
    fi
}

_saas_vault_integrate_minio() {
    local vault_release="" minio_release="" minio_context="" minio_namespace=""
    local eso_namespace="external-secrets" eso_serviceaccount="external-secrets"
    local output_dir="" seed=true yes=false

    local args
    args=$(getopt -o yh -l vault-release:,minio-release:,minio-context:,minio-namespace:,eso-namespace:,eso-serviceaccount:,output-dir:,no-seed,yes,help --name saas_vault_integrate_minio -- "$@") || {
        _saas_vault_integrate_minio_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --vault-release)     vault_release="$2"; shift 2 ;;
            --minio-release)      minio_release="$2"; shift 2 ;;
            --minio-context)      minio_context="$2"; shift 2 ;;
            --minio-namespace)    minio_namespace="$2"; shift 2 ;;
            --eso-namespace)      eso_namespace="$2"; shift 2 ;;
            --eso-serviceaccount) eso_serviceaccount="$2"; shift 2 ;;
            --output-dir)         output_dir="$2"; shift 2 ;;
            --no-seed)            seed=false; shift ;;
            -y|--yes)             yes=true; shift ;;
            -h|--help)            _saas_vault_integrate_minio_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$vault_release" ] || vault_release="$(_saas_vault_suggest_release)"
    if [ -z "$minio_release" ] && [ -z "$minio_context" ]; then
        _saas_log_err "Either --minio-release or --minio-context is required."
        return 1
    fi

    # --- Phase A, step 1: confirm THIS Vault release is up and unsealed ---
    _saas_vault_state_load "$vault_release" || { _saas_log_err "No saved state for Vault release '$vault_release'."; return 1; }
    local ob_ns="$SAAS_VAULT_STATE_NAMESPACE"
    local live_status
    live_status="$(_saas_vault_verify_status "$ob_ns" "$vault_release" 2>/dev/null)"
    case "$live_status" in
        *sealed=false*) : ;;
        *) _saas_log_err "Vault release '$vault_release' is not reachable/unsealed. Nothing else will run."; return 1 ;;
    esac

    # --- Phase A, step 2: resolve the target MinIO context (read-only file read, no coupling) ---
    if [ -z "$minio_context" ]; then
        local minio_state_path="$HOME/.local/state/saas/minio/${minio_release}.env"
        [ -f "$minio_state_path" ] || {
            _saas_log_err "No saved state for minio release '$minio_release' ('$minio_state_path' not found)."
            _saas_log_err "Pass --minio-context explicitly if it wasn't installed with 'saas minio'."
            return 1
        }
        local SAAS_MINIO_STATE_KIND_NAME="" SAAS_MINIO_STATE_NAMESPACE="" SAAS_MINIO_STATE_CLUSTER_MODE=""
        # shellcheck disable=SC1090
        source "$minio_state_path"
        if [ "$SAAS_MINIO_STATE_CLUSTER_MODE" = "kind" ]; then
            minio_context="kind-${SAAS_MINIO_STATE_KIND_NAME}"
        else
            _saas_log_err "minio release '$minio_release' uses --cluster-mode existing; pass --minio-context explicitly."
            return 1
        fi
        [ -n "$minio_namespace" ] || minio_namespace="$SAAS_MINIO_STATE_NAMESPACE"
    fi
    [ -n "$minio_namespace" ] || minio_namespace="${minio_release:-minio}"
    local minio_label="${minio_release:-$minio_context}"

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/vault/${vault_release}/minio-integration/${minio_label}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    # --- Phase A, step 3: is the target cluster reachable at all? ---
    if ! _saas_vault_target_reachable "$minio_context"; then
        _saas_log_err "Could not reach the MinIO cluster (context '$minio_context')."
        _saas_log_err "Nothing on the Vault side has been touched. Make sure the MinIO cluster exists and this kubeconfig context is valid, then re-run."
        return 1
    fi

    # --- Phase A, step 4: does the reviewer ServiceAccount/token already exist there? ---
    if ! _saas_vault_target_reviewer_secret_exists "$minio_context" "$vault_release"; then
        local reviewer_manifest="$output_dir/minio-reviewer-serviceaccount.yaml"
        _saas_vault_render_integration_manifest \
            "$_SAAS_VAULT_DIR/values/gitlab-reviewer-serviceaccount.yaml.tpl" "$reviewer_manifest" \
            "SAAS_VAULT_RELEASE=$vault_release"
        _saas_log_warn "The reviewer ServiceAccount doesn't exist yet in the MinIO cluster."
        _saas_log_info "Manifest written to: $reviewer_manifest"
        _saas_log_info "Apply it with: saas minio integrate vault --release $minio_label --vault-release $vault_release --from-dir $output_dir"
        _saas_log_info "Then re-run this same command to continue (nothing on Vault has been touched yet)."
        return 1
    fi

    # --- Phase B: Vault-side mutation only, from here on ---
    _saas_log_step "Reading the reviewer token from the MinIO cluster (read-only)…"
    local reviewer_token reviewer_ca_b64 k8s_host
    reviewer_token="$(_saas_vault_target_reviewer_token "$minio_context" "$vault_release")"
    reviewer_ca_b64="$(_saas_vault_target_reviewer_ca "$minio_context" "$vault_release")"
    k8s_host="$(_saas_vault_target_api_server "$minio_context")"
    if [ -z "$reviewer_token" ] || [ -z "$k8s_host" ]; then
        _saas_log_err "Could not read the reviewer token or API server address from context '$minio_context'."
        return 1
    fi
    local reviewer_ca_pem
    reviewer_ca_pem="$(echo "$reviewer_ca_b64" | base64 -d 2>/dev/null)"

    local kv_path="minio/${minio_label}"
    local role_name="${vault_release}-minio-${minio_label}-role"
    local policy_name="${vault_release}-minio-${minio_label}-policy"

    _saas_vault_kv_engine_ensure "$vault_release" "$ob_ns" "$kv_path" || return 1
    _saas_vault_k8s_auth_ensure "$vault_release" "$ob_ns" || return 1
    _saas_vault_k8s_auth_configure "$vault_release" "$ob_ns" "$k8s_host" "$reviewer_ca_pem" "$reviewer_token" || return 1
    _saas_vault_policy_write "$vault_release" "$ob_ns" "$policy_name" "path \"${kv_path}/*\" { capabilities = [\"read\"] }" || return 1
    _saas_vault_k8s_role_write "$vault_release" "$ob_ns" "$role_name" "$eso_serviceaccount" "$eso_namespace" "$policy_name" || return 1

    if $seed; then
        _saas_log_step "Seeding MinIO's root credentials into Vault (KV path '$kv_path')…"
        _saas_vault_minio_seed_secrets "$vault_release" "$ob_ns" "$kv_path" "$minio_context" "$minio_namespace" "$minio_label"
    fi

    _saas_log_step "Rendering SecretStore/ExternalSecret manifests…"
    local ca_bundle_b64
    ca_bundle_b64="$(_saas_vault_ca_bundle_b64 "$ob_ns" "$vault_release")"
    local -a common_vars=(
        "SAAS_VAULT_RELEASE=$vault_release"
        "SAAS_VAULT_URL=https://${SAAS_VAULT_STATE_DOMAIN}"
        "SAAS_VAULT_CA_BUNDLE_B64=$ca_bundle_b64"
        "SAAS_MINIO_RELEASE=$minio_label"
        "SAAS_MINIO_NAMESPACE=$minio_namespace"
        "SAAS_ESO_NAMESPACE=$eso_namespace"
        "SAAS_ESO_SERVICEACCOUNT=$eso_serviceaccount"
    )
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/minio-secretstore.yaml.tpl" "$output_dir/minio-secretstore.yaml" "${common_vars[@]}"
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/minio-externalsecret.yaml.tpl" "$output_dir/minio-externalsecret.yaml" "${common_vars[@]}"

    _saas_log_ok "Vault is ready to serve secrets to MinIO release '$minio_label'."
    _saas_log_info "Apply the generated manifests in the MinIO cluster with:"
    _saas_log_info "  saas minio integrate vault --release $minio_label --vault-release $vault_release --from-dir $output_dir"
}
