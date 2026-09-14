# --- saas vault install|up|down|delete|status
#
# Same shape as services/gitlab/lib/install.sh: 'install' resolves every parameter (flags >
# interactive prompts > sensible defaults) and delegates to _saas_vault_provision, which 'up'
# also calls after reloading parameters from the saved state, so there's no second copy of the
# provisioning logic.

_saas_vault_valid_mode()    { [[ "$1" == "dev" || "$1" == "prod" ]]; }
_saas_vault_valid_workers() { [[ "$1" =~ ^[0-9]+$ ]]; }
_saas_vault_valid_key_shares() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
# _saas_vault_valid_key_threshold THRESHOLD SHARES
_saas_vault_valid_key_threshold() {
    local threshold="$1" shares="$2"
    [[ "$threshold" =~ ^[0-9]+$ ]] && [ "$threshold" -ge 1 ] && [ "$threshold" -le "$shares" ]
}

_saas_vault_install_help() {
    cat <<'EOF'
Usage: saas vault install [OPTIONS]

Installs (or updates in place, it's idempotent) OpenBao on Kubernetes: a
local kind cluster or an existing cluster via kubeconfig, cert-manager +
Reloader as cluster prerequisites, an internal PKI chain for Vault's
own Raft/API listener, and fully automated init/unseal (no manual 'bao
operator init'/'bao operator unseal' needed; see 'Modes' below).

Any option that's omitted (except -y/--yes or --non-interactive) is asked
interactively, suggesting the default value in brackets; without a tty or
with --non-interactive that default is used silently (see 'Options with
no safe default' below for the only three exceptions).

Options:
      --release NAME           Helm release name (default: vault)
      --namespace NS           Kubernetes namespace (default: same as
                                --release)
      --cluster-mode MODE      kind (default) or existing
      --kind-name NAME         Name of the kind cluster (kind only;
                                default: same as --release)
      --kind-workers N         Number of worker nodes in the kind cluster
                                (kind only; default: 0)
      --storage-mode MODE      local-path (default) or nfs; only with
                                --cluster-mode kind
      --storage-class NAME     StorageClass to use; only with
                                --cluster-mode existing (default: the
                                cluster's default StorageClass is
                                detected)
      --mode MODE               dev (default) or prod, see 'Modes'
      --version VERSION         Version of the openbao/openbao chart, or
                                'latest' (default). See 'saas vault
                                versions'.
      --domain DOMAIN            Domain to serve Vault's UI/API on.
                                Defaults to '<release>.vault.local'
                                with --tls self-signed. With --tls
                                letsencrypt: required, no safe default.
      --tls MODE                 self-signed (default) or letsencrypt,
                                for the EXTERNAL/ingress certificate
                                only. Vault's internal Raft/API
                                listener always uses its own
                                cert-manager-issued internal CA,
                                independent of this flag
      --challenge TYPE           http01 or dns01; only with --tls
                                letsencrypt. Default: dns01 with
                                --cluster-mode kind (no public
                                reachability), http01 with --cluster-mode
                                existing
      --dns-provider PROVIDER    cloudflare (only option; only with
                                --challenge dns01)
      --dns-token TOKEN          Cloudflare API token, required with
                                --challenge dns01, no safe default
      --email EMAIL              Let's Encrypt account email, required
                                with --tls letsencrypt, no safe default
      --ingress-class NAME       IngressClass to use (default: nginx)
      --key-shares N             Shamir key shares (default: 5)
      --key-threshold N          Shamir key threshold, must be
                                <= --key-shares (default: 3)
      --integrate-gitlab NAME    After Vault is up, best-effort attempt
                                'saas vault integrate gitlab
                                --gitlab-release NAME' (see 'saas vault
                                integrate gitlab --help'). Never fails
                                this install if the gitlab cluster isn't
                                reachable yet: only a warning is printed
  -y, --yes                      Don't ask anything; use the default
                                values without confirmation
      --non-interactive          Same as --yes for the fill-in prompts
  -h, --help                     Show this help

Modes (--mode):
  dev    Single-node Raft (still genuine integrated storage, just no
         retry_join needed with one voter), reduced resources. Meant for
         --cluster-mode kind.
  prod   3-replica HA Raft, each node joining the other two over mTLS,
         resources aligned to a real HA baseline.

  Both modes: init ('bao operator init') and unseal are fully automated.
  The root token and every Shamir key share are captured the moment
  they're produced and saved locally (never printed unless asked for,
  see 'saas vault credentials --help'); only a --key-threshold-sized
  subset of the shares ever makes it into an in-cluster Secret (read by
  an unseal-sidecar container), the root token never does.

Options with no safe default (asked with no suggestion, and DO fail in
--non-interactive if missing, there's no reasonable automatic choice):
  --domain (with --tls letsencrypt), --email (with --tls letsencrypt),
  --dns-token (with --challenge dns01)

Examples:
  saas vault install
  saas vault install --release demo --mode dev
  saas vault install --mode prod --tls letsencrypt --challenge http01 \
      --domain vault.mycompany.com --email me@mycompany.com
  saas vault install --integrate-gitlab gitlab
  saas vault install --non-interactive -y
EOF
}

_saas_vault_install() {
    local release="" namespace="" cluster_mode="kind" kind_name="" kind_workers="0"
    local storage_mode="local-path" storage_class=""
    local mode="dev" version="latest" domain="" tls="self-signed"
    local challenge="" dns_provider="cloudflare" dns_token="" email=""
    local ingress_class="nginx" key_shares="5" key_threshold="3"
    local integrate_gitlab_name=""
    local yes=false non_interactive=false

    local release_set=false namespace_set=false cluster_mode_set=false kind_name_set=false
    local kind_workers_set=false storage_mode_set=false storage_class_set=false
    local mode_set=false version_set=false domain_set=false tls_set=false
    local challenge_set=false dns_provider_set=false ingress_class_set=false
    local key_shares_set=false key_threshold_set=false

    local args
    args=$(getopt -o yh -l release:,namespace:,cluster-mode:,kind-name:,kind-workers:,storage-mode:,storage-class:,mode:,version:,domain:,tls:,challenge:,dns-provider:,dns-token:,email:,ingress-class:,key-shares:,key-threshold:,integrate-gitlab:,yes,non-interactive,help --name saas_vault_install -- "$@") || {
        _saas_vault_install_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release)         release="$2"; release_set=true; shift 2 ;;
            --namespace)       namespace="$2"; namespace_set=true; shift 2 ;;
            --cluster-mode)    cluster_mode="$2"; cluster_mode_set=true; shift 2 ;;
            --kind-name)       kind_name="$2"; kind_name_set=true; shift 2 ;;
            --kind-workers)    kind_workers="$2"; kind_workers_set=true; shift 2 ;;
            --storage-mode)    storage_mode="$2"; storage_mode_set=true; shift 2 ;;
            --storage-class)   storage_class="$2"; storage_class_set=true; shift 2 ;;
            --mode)            mode="$2"; mode_set=true; shift 2 ;;
            --version)         version="$2"; version_set=true; shift 2 ;;
            --domain)          domain="$2"; domain_set=true; shift 2 ;;
            --tls)             tls="$2"; tls_set=true; shift 2 ;;
            --challenge)       challenge="$2"; challenge_set=true; shift 2 ;;
            --dns-provider)    dns_provider="$2"; dns_provider_set=true; shift 2 ;;
            --dns-token)       dns_token="$2"; shift 2 ;;
            --email)           email="$2"; shift 2 ;;
            --ingress-class)   ingress_class="$2"; ingress_class_set=true; shift 2 ;;
            --key-shares)      key_shares="$2"; key_shares_set=true; shift 2 ;;
            --key-threshold)   key_threshold="$2"; key_threshold_set=true; shift 2 ;;
            --integrate-gitlab) integrate_gitlab_name="$2"; shift 2 ;;
            -y|--yes)          yes=true; shift ;;
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_vault_install_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    $yes && non_interactive=true

    _saas_check_deps kubectl helm jq envsubst || return 1

    # --- identity (release/namespace) ---
    $release_set || release="$(_saas_prompt "Release name" "vault" "$non_interactive")"
    [ -n "$release" ] || { _saas_log_err "--release cannot be empty."; return 1; }
    $namespace_set || namespace="$(_saas_prompt "Kubernetes namespace" "$release" "$non_interactive")"

    # --- cluster mode ---
    if $cluster_mode_set; then
        _saas_vault_valid_cluster_mode "$cluster_mode" || { _saas_log_err "--cluster-mode must be 'kind' or 'existing'."; return 1; }
    else
        cluster_mode="$(_saas_prompt_menu "Cluster mode" "kind" "$non_interactive" kind existing)"
    fi

    if [ "$cluster_mode" = "kind" ]; then
        if $storage_class_set; then
            _saas_log_err "--storage-class only applies with --cluster-mode existing; use --storage-mode for 'kind'."
            return 1
        fi
        $kind_name_set || kind_name="$(_saas_prompt "kind cluster name" "$release" "$non_interactive")"
        $kind_workers_set || kind_workers="$(_saas_prompt_validated "Number of worker nodes for the kind cluster" "$kind_workers" "$non_interactive" "must be an integer >= 0" _saas_vault_valid_workers)" || return 1
        $storage_mode_set || storage_mode="$(_saas_prompt_menu "kind cluster storage mode" "local-path" "$non_interactive" local-path nfs)"
        [[ "$storage_mode" == "local-path" || "$storage_mode" == "nfs" ]] || {
            _saas_log_err "--storage-mode must be 'local-path' or 'nfs'."; return 1;
        }
    else
        if $storage_mode_set; then
            _saas_log_err "--storage-mode only applies with --cluster-mode kind; use --storage-class for an existing cluster."
            return 1
        fi
        kubectl cluster-info >/dev/null 2>&1 || {
            _saas_log_err "Could not reach the active kubeconfig's cluster (--cluster-mode existing)."
            return 1
        }
    fi

    # --- dev/prod mode ---
    $mode_set || mode="$(_saas_prompt_menu "Install mode" "dev" "$non_interactive" dev prod)"
    _saas_vault_valid_mode "$mode" || { _saas_log_err "--mode must be 'dev' or 'prod'."; return 1; }

    # --- chart version ---
    version="$(_saas_vault_version_resolve "$version")" || return 1

    # --- key shares/threshold ---
    $key_shares_set || key_shares="$(_saas_prompt_validated "Shamir key shares" "$key_shares" "$non_interactive" "must be an integer >= 1" _saas_vault_valid_key_shares)" || return 1
    _saas_vault_valid_key_shares "$key_shares" || { _saas_log_err "--key-shares must be an integer >= 1."; return 1; }
    if ! $key_threshold_set; then
        key_threshold="$(_saas_prompt "Shamir key threshold" "$key_threshold" "$non_interactive")"
    fi
    _saas_vault_valid_key_threshold "$key_threshold" "$key_shares" || { _saas_log_err "--key-threshold must be an integer >= 1 and <= --key-shares ($key_shares)."; return 1; }

    # --- external TLS ---
    if $tls_set; then
        _saas_vault_valid_tls_mode "$tls" || { _saas_log_err "--tls must be 'self-signed' or 'letsencrypt'."; return 1; }
    else
        tls="$(_saas_prompt_menu "External TLS type" "self-signed" "$non_interactive" self-signed letsencrypt)"
    fi

    local issuer_name="${release}-vault-issuer"
    if [ "$tls" = "letsencrypt" ]; then
        [ -n "$email" ] || {
            if $non_interactive || [ ! -t 0 ]; then
                _saas_log_err "--email is required with --tls letsencrypt (no safe default possible)."
                return 1
            fi
            printf "Let's Encrypt account email (required): " >&2
            read -r email
            [ -n "$email" ] || { _saas_log_err "Empty email."; return 1; }
        }

        if ! $challenge_set; then
            local challenge_default="http01"
            [ "$cluster_mode" = "kind" ] && challenge_default="dns01"
            challenge="$(_saas_prompt_menu "ACME challenge type" "$challenge_default" "$non_interactive" http01 dns01)"
        fi
        _saas_vault_valid_challenge "$challenge" || { _saas_log_err "--challenge must be 'http01' or 'dns01'."; return 1; }

        if [ "$challenge" = "dns01" ]; then
            $dns_provider_set || dns_provider="$(_saas_prompt "DNS provider" "cloudflare" "$non_interactive")"
            _saas_vault_valid_dns_provider "$dns_provider" || { _saas_log_err "--dns-provider must be 'cloudflare' (the only cert-manager-native provider wired up here)."; return 1; }
            [ -n "$dns_token" ] || {
                if $non_interactive || [ ! -t 0 ]; then
                    _saas_log_err "--dns-token is required with --challenge dns01 (no safe default possible)."
                    return 1
                fi
                printf 'Cloudflare API token (required): ' >&2
                read -r dns_token
                [ -n "$dns_token" ] || { _saas_log_err "Empty token."; return 1; }
            }
        fi
    fi

    # --- domain ---
    if [ -z "$domain" ]; then
        if [ "$tls" = "self-signed" ]; then
            domain="$(_saas_prompt "Domain" "${release}.vault.local" "$non_interactive")"
        else
            if $non_interactive || [ ! -t 0 ]; then
                _saas_log_err "--domain is required with --tls letsencrypt (no safe default possible)."
                return 1
            fi
            printf 'Domain to serve Vault on (required, e.g. vault.mycompany.com): ' >&2
            read -r domain
            [ -n "$domain" ] || { _saas_log_err "Empty domain."; return 1; }
        fi
    fi

    # --- remaining options, all with a safe default ---
    $ingress_class_set || ingress_class="$(_saas_prompt "IngressClass" "nginx" "$non_interactive")"

    # --- StorageClass (existing cluster only) ---
    if [ "$cluster_mode" = "existing" ]; then
        storage_class="$(_saas_resolve_storage_class "$storage_class" "$non_interactive")" || return 1
    fi

    _saas_vault_provision "$release" "$namespace" "$cluster_mode" "$kind_name" "$kind_workers" \
        "$storage_mode" "$storage_class" "$mode" "$version" "$domain" "$tls" "$issuer_name" \
        "$challenge" "$dns_provider" "$dns_token" "$email" "$ingress_class" \
        "$key_shares" "$key_threshold" "$integrate_gitlab_name"
}

# _saas_vault_render_values_layer SRC DOMAIN RELEASE NAMESPACE INGRESS_CLASS TLS_SECRET STORAGE_CLASS FULLNAME
_saas_vault_render_values_layer() {
    local src="$1" domain="$2" release="$3" namespace="$4" ingress_class="$5" tls_secret="$6" storage_class="$7" fullname="$8"
    local out
    out="$(mktemp "${TMPDIR:-/tmp}/saas-vault-values-XXXXXX.yaml")" || return 1
    SAAS_DOMAIN="$domain" SAAS_RELEASE="$release" SAAS_NAMESPACE="$namespace" \
        SAAS_INGRESS_CLASS="$ingress_class" SAAS_TLS_SECRET="$tls_secret" \
        SAAS_STORAGE_CLASS="$storage_class" SAAS_FULLNAME="$fullname" \
        envsubst '${SAAS_DOMAIN} ${SAAS_RELEASE} ${SAAS_NAMESPACE} ${SAAS_INGRESS_CLASS} ${SAAS_TLS_SECRET} ${SAAS_STORAGE_CLASS} ${SAAS_FULLNAME}' \
        < "$src" > "$out" || return 1
    echo "$out"
}

# _saas_vault_provision RELEASE NAMESPACE CLUSTER_MODE KIND_NAME KIND_WORKERS STORAGE_MODE \
#   STORAGE_CLASS MODE VERSION DOMAIN TLS ISSUER_NAME CHALLENGE DNS_PROVIDER DNS_TOKEN EMAIL \
#   INGRESS_CLASS KEY_SHARES KEY_THRESHOLD INTEGRATE_GITLAB_NAME
#
# Actually provisions everything (cluster, prerequisites, internal PKI, external TLS, chart,
# init/unseal) and persists the state. Shared by 'install' and 'up'.
_saas_vault_provision() {
    local release="$1" namespace="$2" cluster_mode="$3" kind_name="$4" kind_workers="$5"
    local storage_mode="$6" storage_class="$7" mode="$8" version="$9" domain="${10}" tls="${11}" issuer_name="${12}"
    local challenge="${13}" dns_provider="${14}" dns_token="${15}" email="${16}" ingress_class="${17}"
    local key_shares="${18}" key_threshold="${19}" integrate_gitlab_name="${20}"

    local fullname
    fullname="$(_saas_vault_fullname "$release")"

    # Early checkpoint: enough to know this release's identity/mode/Shamir parameters even if
    # something fails further down.
    _saas_vault_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "MODE=$mode" "KEY_SHARES=$key_shares" "KEY_THRESHOLD=$key_threshold" "STATUS=provisioning"

    if [ "$cluster_mode" = "kind" ]; then
        if _saas_vault_cluster_exists "$kind_name"; then
            _saas_log_info "The kind cluster '$kind_name' already exists, reusing it."
        else
            _saas_vault_cluster_create "$kind_name" "$kind_workers" "$storage_mode" true true || return 1
        fi
        _saas_vault_cluster_use "$kind_name" || return 1
        storage_class=""
    fi

    _saas_log_step "Ensuring cluster prerequisites (cert-manager, Reloader)…"
    _saas_ensure_certmanager || return 1
    _saas_vault_operator_reloader_ensure || return 1

    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    _saas_log_step "Bootstrapping Vault's internal PKI (Raft/API listener)…"
    _saas_vault_internal_pki_bootstrap "$namespace" "$release" || return 1

    _saas_log_step "Configuring external TLS (cert-manager)…"
    case "$tls" in
        self-signed)
            _saas_vault_certmanager_issuer_selfsigned "$issuer_name" || return 1
            ;;
        letsencrypt)
            if [ "$challenge" = "http01" ]; then
                _saas_vault_certmanager_issuer_letsencrypt_http01 "$issuer_name" "$email" "$ingress_class" || return 1
            else
                _saas_vault_certmanager_issuer_letsencrypt_dns01_cloudflare "$issuer_name" "$email" "$dns_token" || return 1
            fi
            ;;
    esac
    local tls_secret="${release}-vault-tls"
    _saas_vault_certificate_request "$namespace" "${release}-vault-cert" "$domain" "$issuer_name" "$tls_secret" || return 1

    _saas_log_step "Installing Vault (chart openbao/openbao @ ${version}), this can take a few minutes…"
    _saas_vault_helm_repo_ensure || return 1
    local tpl_file="$_SAAS_VAULT_DIR/values/${mode}.yaml.tpl"
    [ -f "$tpl_file" ] || { _saas_log_err "The values template '$tpl_file' doesn't exist."; return 1; }

    local -a rendered_files=() value_files=()
    local layer
    layer="$(_saas_vault_render_values_layer "$tpl_file" "$domain" "$release" "$namespace" "$ingress_class" "$tls_secret" "$storage_class" "$fullname")" || { rm -f "${rendered_files[@]}"; return 1; }
    rendered_files+=("$layer"); value_files+=(-f "$layer")
    layer="$(_saas_vault_render_values_layer "$_SAAS_VAULT_DIR/values/unseal.yaml.tpl" "$domain" "$release" "$namespace" "$ingress_class" "$tls_secret" "$storage_class" "$fullname")" || { rm -f "${rendered_files[@]}"; return 1; }
    rendered_files+=("$layer"); value_files+=(-f "$layer")

    # Deliberately no '--wait' here: the chart's default readiness probe reports a sealed pod as
    # not-Ready, so 'helm --wait' would block until timeout on every fresh install, before there's
    # any chance to run 'bao operator init'/unseal it. Wait for the pod to be Running (not Ready)
    # instead, just below, which is all that's needed to 'kubectl exec' into it.
    helm upgrade --install "$release" openbao/openbao \
        --namespace "$namespace" --create-namespace \
        --version "$version" "${value_files[@]}" \
        --timeout 10m
    local helm_status=$?
    rm -f "${rendered_files[@]}"
    [ "$helm_status" -eq 0 ] || { _saas_log_err "The Vault chart install failed."; return 1; }

    local pod="${fullname}-0"
    _saas_log_wait "Waiting for Vault's pod to start (it won't report Ready until unsealed)…"
    local i pod_phase=""
    for i in $(seq 1 36); do
        pod_phase="$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
        [ "$pod_phase" = "Running" ] && break
        sleep 5
    done
    [ "$pod_phase" = "Running" ] || { _saas_log_err "Vault's pod '$pod' never reached Running (last phase: '${pod_phase:-none}')."; return 1; }

    _saas_vault_init_ensure "$release" "$namespace" "$key_shares" "$key_threshold" || return 1
    _saas_vault_wait_unsealed "$release" "$namespace" || return 1
    if [ "$mode" = "prod" ]; then
        # prod.yaml.tpl hardcodes 3 replicas; no user-facing replica-count flag exists.
        _saas_vault_wait_ha_replicas_unsealed "$release" "$namespace" 3 || return 1
    fi

    _saas_vault_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "KIND_NAME=$kind_name" "KIND_WORKERS=$kind_workers" "STORAGE_MODE=$storage_mode" "STORAGE_CLASS=$storage_class" \
        "MODE=$mode" "VERSION=$version" "DOMAIN=$domain" "TLS=$tls" "ISSUER_NAME=$issuer_name" \
        "CHALLENGE=$challenge" "DNS_PROVIDER=$dns_provider" "EMAIL=$email" "INGRESS_CLASS=$ingress_class" \
        "KEY_SHARES=$key_shares" "KEY_THRESHOLD=$key_threshold" \
        "STATUS=up"

    _saas_log_ok "Vault '$release' is ready."
    _saas_vault_credentials "$release"

    if [ -n "$integrate_gitlab_name" ]; then
        _saas_log_step "Attempting GitLab integration with '$integrate_gitlab_name' (best-effort; will not fail this install)…"
        _saas_vault_integrate_gitlab --vault-release "$release" --gitlab-release "$integrate_gitlab_name" -y || \
            _saas_log_warn "GitLab integration with '$integrate_gitlab_name' didn't complete yet (see above). Re-run: saas vault integrate gitlab --vault-release $release --gitlab-release $integrate_gitlab_name"
    fi
}

_saas_vault_up_help() {
    cat <<'EOF'
Usage: saas vault up [RELEASE] [OPTIONS]

Recreates RELEASE's kind cluster (previously destroyed with 'saas
vault down', without --purge-storage) and reinstalls Vault, reusing
the state saved from the original install. Whether the underlying Raft
data survives the cycle depends on the cluster's storage setup (with
kind's default local-path storage it typically does NOT, since a fresh
PVC binds to a fresh, empty host directory rather than the old one);
either way, Vault ends up initialized and unsealed automatically with
no manual input; if the old data didn't survive, this means fresh
keys/root token too (the old ones can never unseal a store they didn't
create), reported via 'saas vault credentials --reveal-root-token'
same as any first install. Only applies to installs with --cluster-mode
kind.

Options:
  -y, --yes       Don't ask for anything extra
  -h, --help      Show this help

Examples:
  saas vault up
  saas vault up demo
EOF
}

_saas_vault_up() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_vault_up -- "$@") || { _saas_vault_up_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_vault_up_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'. Use 'saas vault install' first."; return 1; }
    [ "$SAAS_VAULT_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'up' only applies to installs with --cluster-mode kind."; return 1; }

    _saas_vault_provision "$SAAS_VAULT_STATE_RELEASE" "$SAAS_VAULT_STATE_NAMESPACE" "$SAAS_VAULT_STATE_CLUSTER_MODE" \
        "$SAAS_VAULT_STATE_KIND_NAME" "$SAAS_VAULT_STATE_KIND_WORKERS" "$SAAS_VAULT_STATE_STORAGE_MODE" "" \
        "$SAAS_VAULT_STATE_MODE" "$SAAS_VAULT_STATE_VERSION" "$SAAS_VAULT_STATE_DOMAIN" "$SAAS_VAULT_STATE_TLS" \
        "$SAAS_VAULT_STATE_ISSUER_NAME" "$SAAS_VAULT_STATE_CHALLENGE" "$SAAS_VAULT_STATE_DNS_PROVIDER" "" \
        "$SAAS_VAULT_STATE_EMAIL" "$SAAS_VAULT_STATE_INGRESS_CLASS" \
        "$SAAS_VAULT_STATE_KEY_SHARES" "$SAAS_VAULT_STATE_KEY_THRESHOLD" ""
}

_saas_vault_down_help() {
    cat <<'EOF'
Usage: saas vault down [RELEASE] [OPTIONS]

Destroys RELEASE's kind cluster (host CPU/RAM usage drops to zero).
Never removes the saved root token/unseal keys (untouched by 'down'
regardless). Whether the Raft data itself survives depends on the
cluster's storage setup: see 'saas vault up --help'. Only applies to
installs with --cluster-mode kind.

Options:
  -y, --yes       Don't ask for confirmation
  -h, --help      Show this help

Examples:
  saas vault down
  saas vault down demo -y
EOF
}

_saas_vault_down() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_vault_down -- "$@") || { _saas_vault_down_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_vault_down_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    [ "$SAAS_VAULT_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'down' only applies to installs with --cluster-mode kind."; return 1; }

    echo "This will destroy the kind cluster '$SAAS_VAULT_STATE_KIND_NAME' (data and saved unseal keys are preserved)." >&2
    _saas_confirm "$yes" || return 1

    _saas_vault_cluster_delete "$SAAS_VAULT_STATE_KIND_NAME" false || return 1
    _saas_vault_state_save "$release" \
        "RELEASE=$SAAS_VAULT_STATE_RELEASE" "NAMESPACE=$SAAS_VAULT_STATE_NAMESPACE" "CLUSTER_MODE=$SAAS_VAULT_STATE_CLUSTER_MODE" \
        "KIND_NAME=$SAAS_VAULT_STATE_KIND_NAME" "KIND_WORKERS=$SAAS_VAULT_STATE_KIND_WORKERS" "STORAGE_MODE=$SAAS_VAULT_STATE_STORAGE_MODE" "STORAGE_CLASS=$SAAS_VAULT_STATE_STORAGE_CLASS" \
        "MODE=$SAAS_VAULT_STATE_MODE" "VERSION=$SAAS_VAULT_STATE_VERSION" "DOMAIN=$SAAS_VAULT_STATE_DOMAIN" "TLS=$SAAS_VAULT_STATE_TLS" "ISSUER_NAME=$SAAS_VAULT_STATE_ISSUER_NAME" \
        "CHALLENGE=$SAAS_VAULT_STATE_CHALLENGE" "DNS_PROVIDER=$SAAS_VAULT_STATE_DNS_PROVIDER" "EMAIL=$SAAS_VAULT_STATE_EMAIL" "INGRESS_CLASS=$SAAS_VAULT_STATE_INGRESS_CLASS" \
        "KEY_SHARES=$SAAS_VAULT_STATE_KEY_SHARES" "KEY_THRESHOLD=$SAAS_VAULT_STATE_KEY_THRESHOLD" \
        "STATUS=down"
    _saas_log_ok "kind cluster '$SAAS_VAULT_STATE_KIND_NAME' destroyed. Data and unseal keys preserved. Use 'saas vault up $release' to bring it back up."
}

_saas_vault_delete_help() {
    cat <<'EOF'
Usage: saas vault delete [RELEASE] [OPTIONS]

Full uninstall: removes Vault, its namespace, and (in --cluster-mode
kind) the cluster itself. Also removes the saved install-parameter
state.

The saved root token/unseal keys are removed ONLY with --purge-storage:
without it, they're kept in case the underlying Raft data is still
genuinely there (--cluster-mode existing, or a storage setup where PVCs
really do rebind to old data), since a future install would need those
exact key shares to ever unseal it again. With kind's default storage
this data usually doesn't survive anyway (see 'saas vault up --help'),
in which case the kept keys are simply harmless leftovers, silently
superseded by a fresh init next time. A warning is printed either way so
this is never silently ambiguous.

Options:
      --purge-storage   Also removes the Raft data persisted on the host,
                        AND the saved root token/unseal keys
                        (--cluster-mode kind only). Irreversible
  -y, --yes             Don't ask for confirmation
  -h, --help             Show this help

Examples:
  saas vault delete
  saas vault delete demo --purge-storage -y
EOF
}

_saas_vault_delete() {
    local release="" yes=false purge=false
    local args
    args=$(getopt -o yh -l purge-storage,yes,help --name saas_vault_delete -- "$@") || { _saas_vault_delete_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --purge-storage) purge=true; shift ;;
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_vault_delete_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "This will completely remove the Vault install '$release'$($purge && echo ' (including the data and saved unseal keys, --purge-storage)')." >&2
    _saas_confirm "$yes" || return 1

    if [ "$SAAS_VAULT_STATE_CLUSTER_MODE" = "kind" ]; then
        _saas_vault_cluster_delete "$SAAS_VAULT_STATE_KIND_NAME" "$purge" || return 1
    else
        helm uninstall "$SAAS_VAULT_STATE_RELEASE" --namespace "$SAAS_VAULT_STATE_NAMESPACE" 2>/dev/null
        kubectl delete clusterissuer "$SAAS_VAULT_STATE_ISSUER_NAME" --ignore-not-found >/dev/null 2>&1
        kubectl delete clusterissuer "${release}-vault-selfsigned-issuer" "${release}-vault-internal-ca-issuer" --ignore-not-found >/dev/null 2>&1
        $purge && kubectl delete namespace "$SAAS_VAULT_STATE_NAMESPACE" --ignore-not-found >/dev/null 2>&1
    fi

    _saas_vault_state_delete "$release"
    if $purge; then
        _saas_vault_secrets_delete "$release"
    else
        _saas_vault_secrets_exists "$release" && _saas_log_warn "Unseal keys for '$release' were kept at $(_saas_vault_secrets_path "$release") since storage wasn't purged; delete manually if you no longer need them."
    fi
    _saas_log_ok "Install '$release' removed."
}

_saas_vault_status_help() {
    cat <<'EOF'
Usage: saas vault status [RELEASE] [OPTIONS]

Shows RELEASE's saved state and, if the cluster is reachable, the real
status of its pods.

Options:
  -h, --help   Show this help
EOF
}

_saas_vault_status() {
    local release=""
    case "${1:-}" in -h|--help) _saas_vault_status_help; return 0 ;; esac
    release="${1:-$(_saas_vault_suggest_release)}"

    _saas_vault_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "Release:        $SAAS_VAULT_STATE_RELEASE"
    echo "Namespace:      $SAAS_VAULT_STATE_NAMESPACE"
    echo "Cluster:        $SAAS_VAULT_STATE_CLUSTER_MODE${SAAS_VAULT_STATE_KIND_NAME:+ ($SAAS_VAULT_STATE_KIND_NAME)}"
    echo "Mode:           $SAAS_VAULT_STATE_MODE"
    echo "Chart version:  $SAAS_VAULT_STATE_VERSION"
    echo "Domain:         $SAAS_VAULT_STATE_DOMAIN"
    echo "External TLS:   $SAAS_VAULT_STATE_TLS"
    echo "Key shares:     $SAAS_VAULT_STATE_KEY_SHARES (threshold $SAAS_VAULT_STATE_KEY_THRESHOLD)"
    echo "Saved status:   $SAAS_VAULT_STATE_STATUS"

    if [ "$SAAS_VAULT_STATE_CLUSTER_MODE" = "kind" ] && ! _saas_vault_cluster_exists "$SAAS_VAULT_STATE_KIND_NAME" 2>/dev/null; then
        echo
        echo "The kind cluster doesn't currently exist (a 'saas vault down' pending 'up'?)."
        return 0
    fi

    if kubectl -n "$SAAS_VAULT_STATE_NAMESPACE" get pods >/dev/null 2>&1; then
        echo
        kubectl -n "$SAAS_VAULT_STATE_NAMESPACE" get pods
    fi
}
