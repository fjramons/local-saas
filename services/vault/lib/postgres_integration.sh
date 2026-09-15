# --- 'saas vault integrate postgres': wires this Vault release up as a secrets backend for a
# postgres instance managed by 'saas postgres' (possibly in a different cluster), for External
# Secrets Operator to consume. See services/postgres/lib/vault_integration.sh for the symmetric
# 'saas postgres integrate vault' counterpart that applies the manifests generated here INTO the
# postgres cluster: this file never mutates any cluster except Vault's own, by design (see
# CLAUDE.md). Direct structural copy of minio_integration.sh's two-phase design, reusing every
# generic helper in integration_common.sh unchanged.

_saas_vault_integrate_postgres_help() {
    cat <<'EOF'
Usage: saas vault integrate postgres [OPTIONS]

Wires this Vault release up as a secrets backend for a postgres
instance managed by 'saas postgres', so External Secrets Operator
(ESO) running in the postgres cluster can sync (and, when rotated in
Vault, actually update) its admin credentials.

Two-phase, safely re-runnable at any point, and mutates ONLY this
Vault release, never the postgres cluster:

  Phase A (read-only preflight): confirms this Vault release is up
  and unsealed, resolves the target postgres cluster's kubeconfig
  context, and checks it's reachable. If a reviewer ServiceAccount/
  token isn't present there yet, a manifest is generated for
  'saas postgres integrate vault' to apply, and this command exits
  non-zero with NO Vault-side change at all.

  Phase B (Vault-side mutation): once the reviewer token is confirmed
  present, enables a KV v2 engine and Kubernetes auth trusting the
  postgres cluster, creates a scoped policy/role, seeds postgres's
  real admin credentials, and generates the SecretStore/
  ExternalSecret manifests for 'saas postgres integrate vault' to
  apply there.

A rotation done here only reaches the running database once
'saas postgres doctor --fix' is run on the postgres side: unlike
MinIO, a Postgres role's real password is a database-level fact, not
something a pod restart alone changes.

Running this before 'saas postgres' even exists yet is safe: phase
A's preflight fails cleanly with an actionable message, nothing on
the Vault side is ever touched.

Options:
      --vault-release NAME     This Vault release (default:
                                suggested if only one exists)
      --postgres-release NAME     A 'saas postgres' release to read
                                connection info from (kubeconfig
                                context/namespace); either this or
                                --postgres-context is required
      --postgres-context NAME      Kubeconfig context of the target
                                postgres cluster (overrides what
                                --postgres-release would suggest)
      --postgres-namespace NS      postgres's namespace (default: read
                                from --postgres-release's saved state,
                                or required with --postgres-context
                                alone)
      --eso-namespace NS            Namespace ESO runs in, in the
                                postgres cluster (default: external-secrets)
      --eso-serviceaccount NAME     ESO's ServiceAccount name (default:
                                external-secrets)
      --output-dir DIR               Where to write generated manifests
                                (default: see below)
      --no-seed                      Don't seed postgres's live admin
                                credentials into Vault (phase B still
                                runs, with placeholder values instead)
  -y, --yes                         Don't ask for anything extra
  -h, --help                        Show this help

Default --output-dir:
  ~/.local/state/saas/vault/<vault-release>/postgres-integration/<postgres-release-or-context>/

Examples:
  saas vault integrate postgres --postgres-release postgres
  saas vault integrate postgres --postgres-context kind-postgres --postgres-namespace postgres
EOF
}

# _saas_vault_postgres_seed_secrets VAULT_RELEASE VAULT_NAMESPACE KV_PATH POSTGRES_CONTEXT POSTGRES_NAMESPACE POSTGRES_RELEASE
# Best-effort: reads postgres's OWN live '<release>-credentials' Secret (read-only) and re-writes it
# into Vault's KV path under the exact same field names services/postgres/lib/backend.sh's
# _saas_postgres_secrets_apply already uses (username/password): zero translation needed anywhere.
_saas_vault_postgres_seed_secrets() {
    local vault_release="$1" ob_ns="$2" kv_path="$3" postgres_context="$4" postgres_ns="$5" postgres_release="$6"

    local username password
    username="$(kubectl --context "$postgres_context" -n "$postgres_ns" get secret "${postgres_release}-credentials" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)"
    password="$(kubectl --context "$postgres_context" -n "$postgres_ns" get secret "${postgres_release}-credentials" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [ -n "$username" ]; then
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" postgres "username=$username" "password=$password"
    else
        _saas_log_warn "Could not read postgres's live credentials secret ('${postgres_release}-credentials' in '$postgres_ns'); seeding a placeholder."
        _saas_vault_kv_put "$vault_release" "$ob_ns" "$kv_path" postgres "username=admin" "password=CHANGE-ME"
    fi
}

_saas_vault_integrate_postgres() {
    local vault_release="" postgres_release="" postgres_context="" postgres_namespace=""
    local eso_namespace="external-secrets" eso_serviceaccount="external-secrets"
    local output_dir="" seed=true yes=false

    local args
    args=$(getopt -o yh -l vault-release:,postgres-release:,postgres-context:,postgres-namespace:,eso-namespace:,eso-serviceaccount:,output-dir:,no-seed,yes,help --name saas_vault_integrate_postgres -- "$@") || {
        _saas_vault_integrate_postgres_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --vault-release)      vault_release="$2"; shift 2 ;;
            --postgres-release)   postgres_release="$2"; shift 2 ;;
            --postgres-context)   postgres_context="$2"; shift 2 ;;
            --postgres-namespace) postgres_namespace="$2"; shift 2 ;;
            --eso-namespace)      eso_namespace="$2"; shift 2 ;;
            --eso-serviceaccount) eso_serviceaccount="$2"; shift 2 ;;
            --output-dir)         output_dir="$2"; shift 2 ;;
            --no-seed)            seed=false; shift ;;
            -y|--yes)             yes=true; shift ;;
            -h|--help)            _saas_vault_integrate_postgres_help; return 0 ;;
            --) shift; break ;;
        esac
    done

    [ -n "$vault_release" ] || vault_release="$(_saas_vault_suggest_release)"
    if [ -z "$postgres_release" ] && [ -z "$postgres_context" ]; then
        _saas_log_err "Either --postgres-release or --postgres-context is required."
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

    # --- Phase A, step 2: resolve the target postgres context (read-only file read, no coupling) ---
    if [ -z "$postgres_context" ]; then
        local postgres_state_path="$HOME/.local/state/saas/postgres/${postgres_release}.env"
        [ -f "$postgres_state_path" ] || {
            _saas_log_err "No saved state for postgres release '$postgres_release' ('$postgres_state_path' not found)."
            _saas_log_err "Pass --postgres-context explicitly if it wasn't installed with 'saas postgres'."
            return 1
        }
        local SAAS_POSTGRES_STATE_KIND_NAME="" SAAS_POSTGRES_STATE_NAMESPACE="" SAAS_POSTGRES_STATE_CLUSTER_MODE=""
        # shellcheck disable=SC1090
        source "$postgres_state_path"
        if [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ]; then
            postgres_context="kind-${SAAS_POSTGRES_STATE_KIND_NAME}"
        else
            _saas_log_err "postgres release '$postgres_release' uses --cluster-mode existing; pass --postgres-context explicitly."
            return 1
        fi
        [ -n "$postgres_namespace" ] || postgres_namespace="$SAAS_POSTGRES_STATE_NAMESPACE"
    fi
    [ -n "$postgres_namespace" ] || postgres_namespace="${postgres_release:-postgres}"
    local postgres_label="${postgres_release:-$postgres_context}"

    [ -n "$output_dir" ] || output_dir="$HOME/.local/state/saas/vault/${vault_release}/postgres-integration/${postgres_label}"
    mkdir -p "$output_dir" || { _saas_log_err "Could not create '$output_dir'."; return 1; }

    # --- Phase A, step 3: is the target cluster reachable at all? ---
    if ! _saas_vault_target_reachable "$postgres_context"; then
        _saas_log_err "Could not reach the postgres cluster (context '$postgres_context')."
        _saas_log_err "Nothing on the Vault side has been touched. Make sure the postgres cluster exists and this kubeconfig context is valid, then re-run."
        return 1
    fi

    # --- Phase A, step 4: does the reviewer ServiceAccount/token already exist there? ---
    if ! _saas_vault_target_reviewer_secret_exists "$postgres_context" "$vault_release"; then
        local reviewer_manifest="$output_dir/postgres-reviewer-serviceaccount.yaml"
        _saas_vault_render_integration_manifest \
            "$_SAAS_VAULT_DIR/values/gitlab-reviewer-serviceaccount.yaml.tpl" "$reviewer_manifest" \
            "SAAS_VAULT_RELEASE=$vault_release"
        _saas_log_warn "The reviewer ServiceAccount doesn't exist yet in the postgres cluster."
        _saas_log_info "Manifest written to: $reviewer_manifest"
        _saas_log_info "Apply it with: saas postgres integrate vault --release $postgres_label --vault-release $vault_release --from-dir $output_dir"
        _saas_log_info "Then re-run this same command to continue (nothing on Vault has been touched yet)."
        return 1
    fi

    # --- Phase B: Vault-side mutation only, from here on ---
    _saas_log_step "Reading the reviewer token from the postgres cluster (read-only)…"
    local reviewer_token reviewer_ca_b64 k8s_host
    reviewer_token="$(_saas_vault_target_reviewer_token "$postgres_context" "$vault_release")"
    reviewer_ca_b64="$(_saas_vault_target_reviewer_ca "$postgres_context" "$vault_release")"
    k8s_host="$(_saas_vault_target_api_server "$postgres_context")"
    if [ -z "$reviewer_token" ] || [ -z "$k8s_host" ]; then
        _saas_log_err "Could not read the reviewer token or API server address from context '$postgres_context'."
        return 1
    fi
    local reviewer_ca_pem
    reviewer_ca_pem="$(echo "$reviewer_ca_b64" | base64 -d 2>/dev/null)"

    local kv_path="postgres/${postgres_label}"
    local role_name="${vault_release}-postgres-${postgres_label}-role"
    local policy_name="${vault_release}-postgres-${postgres_label}-policy"

    _saas_vault_kv_engine_ensure "$vault_release" "$ob_ns" "$kv_path" || return 1
    _saas_vault_k8s_auth_ensure "$vault_release" "$ob_ns" || return 1
    _saas_vault_k8s_auth_configure "$vault_release" "$ob_ns" "$k8s_host" "$reviewer_ca_pem" "$reviewer_token" || return 1
    _saas_vault_policy_write "$vault_release" "$ob_ns" "$policy_name" "path \"${kv_path}/*\" { capabilities = [\"read\"] }" || return 1
    _saas_vault_k8s_role_write "$vault_release" "$ob_ns" "$role_name" "$eso_serviceaccount" "$eso_namespace" "$policy_name" || return 1

    if $seed; then
        _saas_log_step "Seeding postgres's admin credentials into Vault (KV path '$kv_path')…"
        _saas_vault_postgres_seed_secrets "$vault_release" "$ob_ns" "$kv_path" "$postgres_context" "$postgres_namespace" "$postgres_label"
    fi

    _saas_log_step "Rendering SecretStore/ExternalSecret manifests…"
    local ca_bundle_b64
    ca_bundle_b64="$(_saas_vault_ca_bundle_b64 "$ob_ns" "$vault_release")"
    local -a common_vars=(
        "SAAS_VAULT_RELEASE=$vault_release"
        "SAAS_VAULT_URL=https://${SAAS_VAULT_STATE_DOMAIN}"
        "SAAS_VAULT_CA_BUNDLE_B64=$ca_bundle_b64"
        "SAAS_POSTGRES_RELEASE=$postgres_label"
        "SAAS_POSTGRES_NAMESPACE=$postgres_namespace"
        "SAAS_ESO_NAMESPACE=$eso_namespace"
        "SAAS_ESO_SERVICEACCOUNT=$eso_serviceaccount"
    )
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/postgres-secretstore.yaml.tpl" "$output_dir/postgres-secretstore.yaml" "${common_vars[@]}"
    _saas_vault_render_integration_manifest "$_SAAS_VAULT_DIR/values/postgres-externalsecret.yaml.tpl" "$output_dir/postgres-externalsecret.yaml" "${common_vars[@]}"

    _saas_log_ok "Vault is ready to serve secrets to postgres release '$postgres_label'."
    _saas_log_info "Apply the generated manifests in the postgres cluster with:"
    _saas_log_info "  saas postgres integrate vault --release $postgres_label --vault-release $vault_release --from-dir $output_dir"
}
