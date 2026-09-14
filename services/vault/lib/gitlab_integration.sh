# --- 'saas vault integrate gitlab': wires this Vault release up as a secrets backend for a
# GitLab instance (possibly in a different cluster), for External Secrets Operator to consume.
# See services/gitlab/lib/vault_integration.sh for the symmetric 'saas gitlab integrate vault'
# counterpart that applies the manifests generated here INTO the GitLab cluster: this file never
# mutates any cluster except Vault's own, by design (see CLAUDE.md).

_saas_vault_integrate_gitlab_help() {
    cat <<'EOF'
Usage: saas vault integrate gitlab [OPTIONS]

Wires this Vault release up as a secrets backend for a GitLab instance
managed by 'saas gitlab', so External Secrets Operator (ESO) running in
the GitLab cluster can sync GitLab's datastore credentials from Vault.

Two-phase, safely re-runnable at any point, and mutates ONLY this
Vault release, never the GitLab cluster:

  Phase A (read-only preflight): confirms this Vault release is up
  and unsealed, resolves the target GitLab cluster's kubeconfig
  context, and checks it's reachable. If a reviewer ServiceAccount/
  token isn't present there yet, a manifest is generated for
  'saas gitlab integrate vault' to apply, and this command exits
  non-zero with NO Vault-side change at all.

  Phase B (Vault-side mutation): once the reviewer token is confirmed
  present, enables a KV v2 engine and Kubernetes auth trusting the
  GitLab cluster, creates a scoped policy/role, optionally seeds
  GitLab's real datastore credentials, and generates the
  SecretStore/ExternalSecret manifests for 'saas gitlab integrate
  vault' to apply there.

Running this before 'saas gitlab' even exists yet is safe: phase A's
preflight fails cleanly with an actionable message, nothing on the
Vault side is ever touched.

Options:
      --vault-release NAME     This Vault release (default:
                                suggested if only one exists)
      --gitlab-release NAME       A 'saas gitlab' release to read
                                connection info from (kubeconfig
                                context/namespace/domain); either this
                                or --gitlab-context is required
      --gitlab-context NAME        Kubeconfig context of the target
                                GitLab cluster (overrides what
                                --gitlab-release would suggest)
      --gitlab-namespace NS        GitLab's namespace (default: read
                                from --gitlab-release's saved state, or
                                required with --gitlab-context alone)
      --eso-namespace NS            Namespace ESO runs in, in the
                                GitLab cluster (default: external-secrets)
      --eso-serviceaccount NAME     ESO's ServiceAccount name (default:
                                external-secrets)
      --output-dir DIR               Where to write generated manifests
                                (default: see below)
      --no-seed                      Don't seed GitLab's live datastore
                                credentials into Vault (phase B still
                                runs, with placeholder values instead)
  -y, --yes                         Don't ask for anything extra
  -h, --help                        Show this help

Default --output-dir:
  ~/.local/state/saas/vault/<vault-release>/gitlab-integration/<gitlab-release-or-context>/

Examples:
  saas vault integrate gitlab --gitlab-release gitlab
  saas vault integrate gitlab --gitlab-context kind-gitlab --gitlab-namespace gitlab
EOF
}

# _saas_vault_gitlab_seed_secrets VAULT_RELEASE VAULT_NAMESPACE KV_PATH GITLAB_CONTEXT GITLAB_NAMESPACE GITLAB_RELEASE
# Best-effort: reads gitlab's OWN live datastore Secrets (read-only) and re-writes them into
# Vault's KV path under the exact same key names services/gitlab/lib/datastore.sh's
# _saas_gitlab_datastore_secrets_apply already uses, so the generated ExternalSecret needs zero
# key translation. Falls back to an obvious placeholder (never silently skipped) if a given
# gitlab Secret can't be read, e.g. gitlab isn't installed yet.
_saas_vault_gitlab_seed_secrets() {
    local vault_release="$1" ob_ns="$2" kv_path="$3" gitlab_context="$4" gitlab_ns="$5" gitlab_release="$6"

    local psql_user psql_pass
    psql_user="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-psql" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)"
    psql_pass="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-psql" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$psql_user" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" psql "username=$psql_user" "password=$psql_pass"
    else
        _saas_log_warn "Could not read gitlab's live PostgreSQL secret ('${gitlab_release}-datastore-psql' in '$gitlab_ns'); seeding a placeholder."
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" psql "username=gitlab" "password=CHANGE-ME"
    fi

    local minio_user minio_pass
    minio_user="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-minio" -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d 2>/dev/null)"
    minio_pass="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-minio" -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$minio_user" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" minio "rootUser=$minio_user" "rootPassword=$minio_pass"
    else
        _saas_log_warn "Could not read gitlab's live MinIO secret ('${gitlab_release}-datastore-minio' in '$gitlab_ns'); seeding a placeholder."
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" minio "rootUser=gitlab-minio" "rootPassword=CHANGE-ME"
    fi

    local objectstore_conn
    objectstore_conn="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-objectstore" -o jsonpath='{.data.connection}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$objectstore_conn" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" objectstore "connection=$objectstore_conn"
    else
        _saas_log_warn "Could not read gitlab's live object storage secret; skipping the 'objectstore' KV entry."
    fi

    local s3cfg
    s3cfg="$(kubectl --context "$gitlab_context" -n "$gitlab_ns" get secret "${gitlab_release}-datastore-s3cfg" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$s3cfg" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" s3cfg "config=$s3cfg"
    else
        _saas_log_warn "Could not read gitlab's live s3cfg secret; skipping the 's3cfg' KV entry."
    fi
}

_saas_vault_integrate_gitlab() {
    local vault_release="" gitlab_release="" gitlab_context="" gitlab_namespace=""
    local eso_namespace="external-secrets" eso_serviceaccount="external-secrets"
    local output_dir="" seed=true yes=false

    local args
    args=$(getopt -o yh -l vault-release:,gitlab-release:,gitlab-context:,gitlab-namespace:,eso-namespace:,eso-serviceaccount:,output-dir:,no-seed,yes,help --name saas_vault_integrate_gitlab -- "$@") || {
        _saas_vault_integrate_gitlab_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --vault-release)    vault_release="$2"; shift 2 ;;
            --gitlab-release)     gitlab_release="$2"; shift 2 ;;
            --gitlab-context)     gitlab_context="$2"; shift 2 ;;
            --gitlab-namespace)   gitlab_namespace="$2"; shift 2 ;;
            --eso-namespace)      eso_namespace="$2"; shift 2 ;;
            --eso-serviceaccount) eso_serviceaccount="$2"; shift 2 ;;
            --output-dir)         output_dir="$2"; shift 2 ;;
            --no-seed)            seed=false; shift ;;
            -y|--yes)             yes=true; shift ;;
            -h|--help)            _saas_vault_integrate_gitlab_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$vault_release" ] || vault_release="$(_saas_vault_suggest_release)"
    if [ -z "$gitlab_release" ] && [ -z "$gitlab_context" ]; then
        _saas_log_err "Either --gitlab-release or --gitlab-context is required."
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

    # --- Phase A, step 2: resolve the target GitLab context (read-only file read, no coupling) ---
    if [ -z "$gitlab_context" ]; then
        local gitlab_state_path="$HOME/.local/state/saas/gitlab/${gitlab_release}.env"
        [ -f "$gitlab_state_path" ] || {
            _saas_log_err "No saved state for gitlab release '$gitlab_release' ('$gitlab_state_path' not found)."
            _saas_log_err "Pass --gitlab-context explicitly if it wasn't installed with 'saas gitlab'."
            return 1
        }
        local SAAS_GITLAB_STATE_KIND_NAME="" SAAS_GITLAB_STATE_NAMESPACE="" SAAS_GITLAB_STATE_DOMAIN="" SAAS_GITLAB_STATE_CLUSTER_MODE=""
        # shellcheck disable=SC1090
        source "$gitlab_state_path"
        if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ]; then
            gitlab_context="kind-${SAAS_GITLAB_STATE_KIND_NAME}"
        else
            _saas_log_err "gitlab release '$gitlab_release' uses --cluster-mode existing; pass --gitlab-context explicitly."
            return 1
        fi
        [ -n "$gitlab_namespace" ] || gitlab_namespace="$SAAS_GITLAB_STATE_NAMESPACE"
    fi
    [ -n "$gitlab_namespace" ] || gitlab_namespace="${gitlab_release:-gitlab}"
    local gitlab_label="${gitlab_release:-$gitlab_context}"

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/vault/${vault_release}/gitlab-integration/${gitlab_label}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    # --- Phase A, step 3: is the target cluster reachable at all? ---
    if ! _saas_vault_target_reachable "$gitlab_context"; then
        _saas_log_err "Could not reach the GitLab cluster (context '$gitlab_context')."
        _saas_log_err "Nothing on the Vault side has been touched. Make sure the GitLab cluster exists and this kubeconfig context is valid, then re-run."
        return 1
    fi

    # --- Phase A, step 4: does the reviewer ServiceAccount/token already exist there? ---
    if ! _saas_vault_target_reviewer_secret_exists "$gitlab_context" "$vault_release"; then
        local reviewer_manifest="$output_dir/gitlab-reviewer-serviceaccount.yaml"
        _saas_vault_render_integration_manifest \
            "$_SAAS_VAULT_DIR/values/gitlab-reviewer-serviceaccount.yaml.tpl" "$reviewer_manifest" \
            "SAAS_VAULT_RELEASE=$vault_release"
        _saas_log_warn "The reviewer ServiceAccount doesn't exist yet in the GitLab cluster."
        _saas_log_info "Manifest written to: $reviewer_manifest"
        _saas_log_info "Apply it with: saas gitlab integrate vault --release $gitlab_label --vault-release $vault_release --from-dir $output_dir"
        _saas_log_info "Then re-run this same command to continue (nothing on Vault has been touched yet)."
        return 1
    fi

    # --- Phase B: Vault-side mutation only, from here on ---
    _saas_log_step "Reading the reviewer token from the GitLab cluster (read-only)…"
    local reviewer_token reviewer_ca_b64 k8s_host
    reviewer_token="$(_saas_vault_target_reviewer_token "$gitlab_context" "$vault_release")"
    reviewer_ca_b64="$(_saas_vault_target_reviewer_ca "$gitlab_context" "$vault_release")"
    k8s_host="$(_saas_vault_target_api_server "$gitlab_context")"
    if [ -z "$reviewer_token" ] || [ -z "$k8s_host" ]; then
        _saas_log_err "Could not read the reviewer token or API server address from context '$gitlab_context'."
        return 1
    fi
    local reviewer_ca_pem
    reviewer_ca_pem="$(echo "$reviewer_ca_b64" | base64 -d 2>/dev/null)"

    local kv_path="gitlab/${gitlab_label}"
    local role_name="${vault_release}-gitlab-${gitlab_label}-role"
    local policy_name="${vault_release}-gitlab-${gitlab_label}-policy"

    _saas_vault_kv_engine_ensure "$vault_release" "$ob_ns" "$kv_path" || return 1
    _saas_vault_k8s_auth_ensure "$vault_release" "$ob_ns" || return 1
    _saas_vault_k8s_auth_configure "$vault_release" "$ob_ns" "$k8s_host" "$reviewer_ca_pem" "$reviewer_token" || return 1
    _saas_vault_policy_write "$vault_release" "$ob_ns" "$policy_name" "path \"${kv_path}/*\" { capabilities = [\"read\"] }" || return 1
    _saas_vault_k8s_role_write "$vault_release" "$ob_ns" "$role_name" "$eso_serviceaccount" "$eso_namespace" "$policy_name" || return 1

    if $seed; then
        _saas_log_step "Seeding GitLab's datastore credentials into Vault (KV path '$kv_path')…"
        _saas_vault_gitlab_seed_secrets "$vault_release" "$ob_ns" "$kv_path" "$gitlab_context" "$gitlab_namespace" "$gitlab_label"
    fi

    _saas_log_step "Rendering SecretStore/ExternalSecret manifests…"
    local ca_bundle_b64
    ca_bundle_b64="$(_saas_vault_ca_bundle_b64 "$ob_ns" "$vault_release")"
    local -a common_vars=(
        "SAAS_VAULT_RELEASE=$vault_release"
        "SAAS_VAULT_URL=https://${SAAS_VAULT_STATE_DOMAIN}"
        "SAAS_VAULT_CA_BUNDLE_B64=$ca_bundle_b64"
        "SAAS_GITLAB_RELEASE=$gitlab_label"
        "SAAS_GITLAB_NAMESPACE=$gitlab_namespace"
        "SAAS_ESO_NAMESPACE=$eso_namespace"
        "SAAS_ESO_SERVICEACCOUNT=$eso_serviceaccount"
    )
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/gitlab-secretstore.yaml.tpl" "$output_dir/gitlab-secretstore.yaml" "${common_vars[@]}"
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/gitlab-externalsecret.yaml.tpl" "$output_dir/gitlab-externalsecret.yaml" "${common_vars[@]}"

    _saas_log_ok "Vault is ready to serve secrets to GitLab release '$gitlab_label'."
    _saas_log_info "Apply the generated manifests in the GitLab cluster with:"
    _saas_log_info "  saas gitlab integrate vault --release $gitlab_label --vault-release $vault_release --from-dir $output_dir"
}
