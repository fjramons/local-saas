# --- saas minio install|up|down|delete|status
#
# Same shape as services/vault/lib/install.sh (closer to vault's simplicity than gitlab's: no
# runner/registry/pages, no SSH exposure, no chart at all). 'install' resolves every parameter
# (flags > interactive prompts > sensible defaults) and delegates to _saas_minio_provision, which
# 'up' also calls after reloading parameters from the saved state.

_saas_minio_valid_mode()    { [[ "$1" == "dev" || "$1" == "prod" ]]; }
_saas_minio_valid_workers() { [[ "$1" =~ ^[0-9]+$ ]]; }
# _saas_minio_valid_bucket_name NAME
# S3's own bucket-naming rules (lowercase, digits, hyphens, dots; 3-63 chars; must start/end with a
# letter or digit): validated here so a typo produces a clear error instead of an opaque 'mc mb'
# failure deep inside a Job's logs.
_saas_minio_valid_bucket_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]
}

_saas_minio_install_help() {
    cat <<'EOF'
Usage: saas minio install [OPTIONS]

Installs (or updates in place, it's idempotent) standalone, S3-compatible
MinIO object storage on Kubernetes: a local kind cluster or an existing
cluster via kubeconfig, cert-manager + TLS, and an Ingress exposing both
the S3 API and the web console.

Any option that's omitted (except -y/--yes or --non-interactive) is asked
interactively, suggesting the default value in brackets; without a tty or
with --non-interactive that default is used silently (see 'Options with
no safe default' below for the only three exceptions).

Options:
      --release NAME           Helm-style release name (default: minio)
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
      --domain DOMAIN            Domain to serve the web console on (the
                                S3 API is served at 's3.<domain>', same
                                certificate). Defaults to
                                '<release>.minio.local' with --tls
                                self-signed. With --tls letsencrypt:
                                required, no safe default possible.
      --tls MODE                 self-signed (default) or letsencrypt
      --challenge TYPE           http01 or dns01; only with --tls
                                letsencrypt. Default: dns01 with
                                --cluster-mode kind (no public
                                reachability), http01 with --cluster-mode
                                existing.
      --dns-provider PROVIDER    cloudflare (only option; only with
                                --challenge dns01)
      --dns-token TOKEN          Cloudflare API token, required with
                                --challenge dns01, no safe default
      --email EMAIL              Let's Encrypt account email, required
                                with --tls letsencrypt, no safe default
      --ingress-class NAME       IngressClass to use (default: nginx)
      --bucket NAME               Pre-create this bucket at install time
                                (repeatable). Default: none; buckets can
                                always be managed later with 'saas minio
                                bucket', see 'saas minio bucket --help'
  -y, --yes                      Don't ask anything; use the default
                                values without confirmation
      --non-interactive          Same as --yes for the fill-in prompts
  -h, --help                     Show this help

Modes (--mode):
  dev    Single instance, reduced resources (5Gi storage). Meant for
         --cluster-mode kind.
  prod   4-node distributed mode (MinIO's own erasure-coded clustering,
         no operator needed), 50Gi storage per node.

Options with no safe default (asked with no suggestion, and DO fail in
--non-interactive if missing, there's no reasonable automatic choice):
  --domain (with --tls letsencrypt), --email (with --tls letsencrypt),
  --dns-token (with --challenge dns01)

Examples:
  saas minio install
  saas minio install --release demo --mode dev --bucket photos --bucket backups
  saas minio install --cluster-mode existing --storage-class gp3 \
      --mode prod --tls letsencrypt --challenge http01 \
      --domain minio.mycompany.com --email me@mycompany.com
  saas minio install --non-interactive -y
EOF
}

_saas_minio_install() {
    local release="" namespace="" cluster_mode="kind" kind_name="" kind_workers="0"
    local storage_mode="local-path" storage_class=""
    local mode="dev" domain="" tls="self-signed"
    local challenge="" dns_provider="cloudflare" dns_token="" email=""
    local ingress_class="nginx"
    local yes=false non_interactive=false
    local -a buckets=()

    local release_set=false namespace_set=false cluster_mode_set=false kind_name_set=false
    local kind_workers_set=false storage_mode_set=false storage_class_set=false
    local mode_set=false domain_set=false tls_set=false
    local challenge_set=false dns_provider_set=false ingress_class_set=false

    local args
    args=$(getopt -o yh -l release:,namespace:,cluster-mode:,kind-name:,kind-workers:,storage-mode:,storage-class:,mode:,domain:,tls:,challenge:,dns-provider:,dns-token:,email:,ingress-class:,bucket:,yes,non-interactive,help --name saas_minio_install -- "$@") || {
        _saas_minio_install_help; return 1
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
            --domain)          domain="$2"; domain_set=true; shift 2 ;;
            --tls)             tls="$2"; tls_set=true; shift 2 ;;
            --challenge)       challenge="$2"; challenge_set=true; shift 2 ;;
            --dns-provider)    dns_provider="$2"; dns_provider_set=true; shift 2 ;;
            --dns-token)       dns_token="$2"; shift 2 ;;
            --email)           email="$2"; shift 2 ;;
            --ingress-class)   ingress_class="$2"; ingress_class_set=true; shift 2 ;;
            --bucket)          buckets+=("$2"); shift 2 ;;
            -y|--yes)          yes=true; shift ;;
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_minio_install_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    $yes && non_interactive=true

    # 'helm' is needed even though MinIO itself is plain manifests (no chart): _saas_ensure_certmanager
    # (lib/common.sh) installs cert-manager via its own chart.
    _saas_check_deps kubectl helm jq envsubst || return 1

    local b
    for b in "${buckets[@]}"; do
        _saas_minio_valid_bucket_name "$b" || {
            _saas_log_err "--bucket '$b' isn't a valid S3 bucket name (lowercase letters/digits/hyphens/dots, 3-63 chars, must start/end with a letter or digit)."
            return 1
        }
    done

    # --- identity (release/namespace) ---
    $release_set || release="$(_saas_prompt "Release name" "minio" "$non_interactive")"
    [ -n "$release" ] || { _saas_log_err "--release cannot be empty."; return 1; }
    $namespace_set || namespace="$(_saas_prompt "Kubernetes namespace" "$release" "$non_interactive")"

    # --- cluster mode ---
    if $cluster_mode_set; then
        _saas_minio_valid_cluster_mode "$cluster_mode" || { _saas_log_err "--cluster-mode must be 'kind' or 'existing'."; return 1; }
    else
        cluster_mode="$(_saas_prompt_menu "Cluster mode" "kind" "$non_interactive" kind existing)"
    fi

    if [ "$cluster_mode" = "kind" ]; then
        if $storage_class_set; then
            _saas_log_err "--storage-class only applies with --cluster-mode existing; use --storage-mode for 'kind'."
            return 1
        fi
        $kind_name_set || kind_name="$(_saas_prompt "kind cluster name" "$release" "$non_interactive")"
        $kind_workers_set || kind_workers="$(_saas_prompt_validated "Number of worker nodes for the kind cluster" "$kind_workers" "$non_interactive" "must be an integer >= 0" _saas_minio_valid_workers)" || return 1
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
    _saas_minio_valid_mode "$mode" || { _saas_log_err "--mode must be 'dev' or 'prod'."; return 1; }

    # --- TLS ---
    if $tls_set; then
        _saas_minio_valid_tls_mode "$tls" || { _saas_log_err "--tls must be 'self-signed' or 'letsencrypt'."; return 1; }
    else
        tls="$(_saas_prompt_menu "TLS type" "self-signed" "$non_interactive" self-signed letsencrypt)"
    fi

    local issuer_name="${release}-minio-issuer"
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
        _saas_minio_valid_challenge "$challenge" || { _saas_log_err "--challenge must be 'http01' or 'dns01'."; return 1; }

        if [ "$challenge" = "dns01" ]; then
            $dns_provider_set || dns_provider="$(_saas_prompt "DNS provider" "cloudflare" "$non_interactive")"
            _saas_minio_valid_dns_provider "$dns_provider" || { _saas_log_err "--dns-provider must be 'cloudflare' (the only cert-manager-native provider wired up here)."; return 1; }
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
            domain="$(_saas_prompt "Domain (console; the S3 API is served at s3.<domain>)" "${release}.minio.local" "$non_interactive")"
        else
            if $non_interactive || [ ! -t 0 ]; then
                _saas_log_err "--domain is required with --tls letsencrypt (no safe default possible)."
                return 1
            fi
            printf 'Domain for the console (required, e.g. minio.mycompany.com; the S3 API is served at s3.<domain>): ' >&2
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

    # Reuse existing root credentials on a re-install against an already-provisioned release, same
    # reasoning as gitlab/vault: the running pod's own env already has the old password baked in,
    # and Kubernetes doesn't restart it just because the Secret it reads from changed.
    local root_user="" root_password=""
    if _saas_minio_state_load "$release"; then
        root_user="$SAAS_MINIO_STATE_ROOT_USER"
        root_password="$SAAS_MINIO_STATE_ROOT_PASSWORD"
    fi

    _saas_minio_provision "$release" "$namespace" "$cluster_mode" "$kind_name" "$kind_workers" \
        "$storage_mode" "$storage_class" "$mode" "$domain" "$tls" "$issuer_name" \
        "$challenge" "$dns_provider" "$dns_token" "$email" "$ingress_class" \
        "$root_user" "$root_password" "${buckets[@]}"
}

# _saas_minio_provision RELEASE NAMESPACE CLUSTER_MODE KIND_NAME KIND_WORKERS STORAGE_MODE \
#   STORAGE_CLASS MODE DOMAIN TLS ISSUER_NAME CHALLENGE DNS_PROVIDER DNS_TOKEN EMAIL \
#   INGRESS_CLASS ROOT_USER ROOT_PASSWORD [BUCKET...]
#
# Actually provisions everything (cluster, backend, TLS, ingress, buckets) and persists the state.
# Shared by 'install' and 'up'. ROOT_USER/ROOT_PASSWORD, if empty, are generated here (first
# install); if non-empty (reused from saved state), kept as-is so as not to break data already on
# disk, same pattern as gitlab/vault's credential handling.
_saas_minio_provision() {
    local release="$1" namespace="$2" cluster_mode="$3" kind_name="$4" kind_workers="$5"
    local storage_mode="$6" storage_class="$7" mode="$8" domain="$9" tls="${10}" issuer_name="${11}"
    local challenge="${12}" dns_provider="${13}" dns_token="${14}" email="${15}" ingress_class="${16}"
    local root_user="${17}" root_password="${18}"
    shift 18
    local -a buckets=("$@")

    [ -n "$root_user" ]     || root_user="minio-root"
    [ -n "$root_password" ] || root_password="$(_saas_random_password 32)"

    local buckets_csv
    buckets_csv="$(IFS=,; echo "${buckets[*]}")"

    # Early checkpoint: a retried 'install' over the same --release reuses these credentials.
    _saas_minio_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "ROOT_USER=$root_user" "ROOT_PASSWORD=$root_password" "STATUS=provisioning"

    if [ "$cluster_mode" = "kind" ]; then
        if _saas_minio_cluster_exists "$kind_name"; then
            _saas_log_info "The kind cluster '$kind_name' already exists, reusing it."
        else
            _saas_minio_cluster_create "$kind_name" "$kind_workers" "$storage_mode" true true || return 1
        fi
        _saas_minio_cluster_use "$kind_name" || return 1
        storage_class=""
    fi

    if [ "$mode" = "prod" ]; then
        _saas_log_step "Deploying MinIO (4-node distributed)…"
        _saas_minio_prod_apply "$namespace" "$release" "$storage_class" "$root_user" "$root_password" || return 1
    else
        _saas_log_step "Deploying MinIO (single instance)…"
        _saas_minio_dev_apply "$namespace" "$release" "$storage_class" "$root_user" "$root_password" || return 1
    fi

    local s3_domain="s3.${domain}"

    _saas_log_step "Configuring TLS (cert-manager)…"
    _saas_ensure_certmanager || return 1
    case "$tls" in
        self-signed)
            _saas_minio_certmanager_issuer_selfsigned "$issuer_name" || return 1
            ;;
        letsencrypt)
            if [ "$challenge" = "http01" ]; then
                _saas_minio_certmanager_issuer_letsencrypt_http01 "$issuer_name" "$email" "$ingress_class" || return 1
            else
                _saas_minio_certmanager_issuer_letsencrypt_dns01_cloudflare "$issuer_name" "$email" "$dns_token" || return 1
            fi
            ;;
    esac
    local tls_secret="${release}-minio-tls"
    _saas_minio_certificate_request "$namespace" "${release}-minio-cert" "$domain" "$issuer_name" "$tls_secret" "$s3_domain" || return 1

    _saas_log_step "Exposing the console and S3 API (Ingress)…"
    _saas_minio_ingress_apply "$namespace" "$release" "$domain" "$s3_domain" "$ingress_class" "$tls_secret" || return 1

    if [ "${#buckets[@]}" -gt 0 ]; then
        _saas_log_step "Pre-creating ${#buckets[@]} bucket(s)…"
        _saas_minio_init_buckets "$namespace" "$release" "${buckets[@]}" || return 1
    fi

    _saas_minio_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "KIND_NAME=$kind_name" "KIND_WORKERS=$kind_workers" "STORAGE_MODE=$storage_mode" "STORAGE_CLASS=$storage_class" \
        "MODE=$mode" "DOMAIN=$domain" "TLS=$tls" "ISSUER_NAME=$issuer_name" \
        "CHALLENGE=$challenge" "DNS_PROVIDER=$dns_provider" "EMAIL=$email" "INGRESS_CLASS=$ingress_class" \
        "BUCKETS=$buckets_csv" \
        "ROOT_USER=$root_user" "ROOT_PASSWORD=$root_password" \
        "STATUS=up"

    _saas_log_ok "MinIO '$release' is ready."
    _saas_minio_credentials "$release"
}

_saas_minio_up_help() {
    cat <<'EOF'
Usage: saas minio up [RELEASE] [OPTIONS]

Recreates RELEASE's kind cluster (previously destroyed with 'saas minio
down', without --purge-storage) and reinstalls MinIO reusing the state
saved from the original install: same credentials, same domain, same
buckets re-created (idempotently). Only applies to installs with
--cluster-mode kind.

Options:
  -y, --yes       Don't ask for anything extra
  -h, --help      Show this help

Examples:
  saas minio up
  saas minio up demo
EOF
}

_saas_minio_up() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_minio_up -- "$@") || { _saas_minio_up_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_minio_up_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'. Use 'saas minio install' first."; return 1; }
    [ "$SAAS_MINIO_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'up' only applies to installs with --cluster-mode kind."; return 1; }

    local -a buckets=()
    if [ -n "${SAAS_MINIO_STATE_BUCKETS:-}" ]; then
        IFS=',' read -r -a buckets <<< "$SAAS_MINIO_STATE_BUCKETS"
    fi

    _saas_minio_provision "$SAAS_MINIO_STATE_RELEASE" "$SAAS_MINIO_STATE_NAMESPACE" "$SAAS_MINIO_STATE_CLUSTER_MODE" \
        "$SAAS_MINIO_STATE_KIND_NAME" "$SAAS_MINIO_STATE_KIND_WORKERS" "$SAAS_MINIO_STATE_STORAGE_MODE" "" \
        "$SAAS_MINIO_STATE_MODE" "$SAAS_MINIO_STATE_DOMAIN" "$SAAS_MINIO_STATE_TLS" \
        "$SAAS_MINIO_STATE_ISSUER_NAME" "$SAAS_MINIO_STATE_CHALLENGE" "$SAAS_MINIO_STATE_DNS_PROVIDER" "" \
        "$SAAS_MINIO_STATE_EMAIL" "$SAAS_MINIO_STATE_INGRESS_CLASS" \
        "$SAAS_MINIO_STATE_ROOT_USER" "$SAAS_MINIO_STATE_ROOT_PASSWORD" "${buckets[@]}"
}

_saas_minio_down_help() {
    cat <<'EOF'
Usage: saas minio down [RELEASE] [OPTIONS]

Destroys RELEASE's kind cluster (host CPU/RAM usage drops to zero) while
preserving the data in the host's storage directory. 'saas minio up'
recovers it when recreating the cluster. Only applies to installs with
--cluster-mode kind.

Options:
  -y, --yes       Don't ask for confirmation
  -h, --help      Show this help

Examples:
  saas minio down
  saas minio down demo -y
EOF
}

_saas_minio_down() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_minio_down -- "$@") || { _saas_minio_down_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_minio_down_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    [ "$SAAS_MINIO_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'down' only applies to installs with --cluster-mode kind."; return 1; }

    echo "This will destroy the kind cluster '$SAAS_MINIO_STATE_KIND_NAME' (data is preserved on the host)." >&2
    _saas_confirm "$yes" || return 1

    _saas_minio_cluster_delete "$SAAS_MINIO_STATE_KIND_NAME" false || return 1
    _saas_minio_state_save_key "$release" "STATUS" "down"
    _saas_log_ok "kind cluster '$SAAS_MINIO_STATE_KIND_NAME' destroyed. Data preserved. Use 'saas minio up $release' to bring it back up."
}

_saas_minio_delete_help() {
    cat <<'EOF'
Usage: saas minio delete [RELEASE] [OPTIONS]

Full uninstall: removes MinIO, its namespace, and (in --cluster-mode
kind) the cluster itself. Also removes the saved state.

Options:
      --purge-storage   Also removes the data persisted on the host
                        (--cluster-mode kind only). Irreversible
  -y, --yes             Don't ask for confirmation
  -h, --help             Show this help

Examples:
  saas minio delete
  saas minio delete demo --purge-storage -y
EOF
}

_saas_minio_delete() {
    local release="" yes=false purge=false
    local args
    args=$(getopt -o yh -l purge-storage,yes,help --name saas_minio_delete -- "$@") || { _saas_minio_delete_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --purge-storage) purge=true; shift ;;
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_minio_delete_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "This will completely remove the MinIO install '$release'$($purge && echo ' (including the data, --purge-storage)')." >&2
    _saas_confirm "$yes" || return 1

    if [ "$SAAS_MINIO_STATE_CLUSTER_MODE" = "kind" ]; then
        _saas_minio_cluster_delete "$SAAS_MINIO_STATE_KIND_NAME" "$purge" || return 1
    else
        kubectl delete clusterissuer "$SAAS_MINIO_STATE_ISSUER_NAME" --ignore-not-found >/dev/null 2>&1
        _saas_minio_backend_delete "$SAAS_MINIO_STATE_NAMESPACE" "$SAAS_MINIO_STATE_RELEASE"
        $purge && kubectl delete namespace "$SAAS_MINIO_STATE_NAMESPACE" --ignore-not-found >/dev/null 2>&1
    fi

    _saas_minio_state_delete "$release"
    _saas_log_ok "Install '$release' removed."
}

_saas_minio_status_help() {
    cat <<'EOF'
Usage: saas minio status [RELEASE] [OPTIONS]

Shows RELEASE's saved state and, if the cluster is reachable, the real
status of its pods.

Options:
  -h, --help   Show this help
EOF
}

_saas_minio_status() {
    local release=""
    case "${1:-}" in -h|--help) _saas_minio_status_help; return 0 ;; esac
    release="${1:-$(_saas_minio_suggest_release)}"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "Release:        $SAAS_MINIO_STATE_RELEASE"
    echo "Namespace:      $SAAS_MINIO_STATE_NAMESPACE"
    echo "Cluster:        $SAAS_MINIO_STATE_CLUSTER_MODE${SAAS_MINIO_STATE_KIND_NAME:+ ($SAAS_MINIO_STATE_KIND_NAME)}"
    echo "Mode:           $SAAS_MINIO_STATE_MODE"
    echo "Domain:         $SAAS_MINIO_STATE_DOMAIN"
    echo "TLS:            $SAAS_MINIO_STATE_TLS"
    echo "Buckets:        ${SAAS_MINIO_STATE_BUCKETS:-(none pre-created)}"
    echo "Saved status:   $SAAS_MINIO_STATE_STATUS"

    if [ "$SAAS_MINIO_STATE_CLUSTER_MODE" = "kind" ] && ! _saas_minio_cluster_exists "$SAAS_MINIO_STATE_KIND_NAME" 2>/dev/null; then
        echo
        echo "The kind cluster doesn't currently exist (a 'saas minio down' pending 'up'?)."
        return 0
    fi

    if kubectl -n "$SAAS_MINIO_STATE_NAMESPACE" get pods >/dev/null 2>&1; then
        echo
        kubectl -n "$SAAS_MINIO_STATE_NAMESPACE" get pods
    fi
}
