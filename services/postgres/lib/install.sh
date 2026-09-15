# --- saas postgres install|up|down|delete|status
#
# Same shape as services/minio/lib/install.sh (closer to minio's simplicity than gitlab's: no
# chart, no runner/registry). 'install' resolves every parameter (flags > interactive prompts >
# sensible defaults) and delegates to _saas_postgres_provision, which 'up' also calls after
# reloading parameters from the saved state.

_saas_postgres_install_help() {
    cat <<'EOF'
Usage: saas postgres install [OPTIONS]

Installs (or updates in place, it's idempotent) standalone PostgreSQL
on Kubernetes: a local kind cluster or an existing cluster via
kubeconfig, cert-manager + TLS enforced on every connection (no
plaintext, see 'saas postgres --help' notes below), and (--mode prod)
real HA via the CloudNativePG operator.

Any option that's omitted (except -y/--yes or --non-interactive) is asked
interactively, suggesting the default value in brackets; without a tty or
with --non-interactive that default is used silently (see 'Options with
no safe default' below for the only three exceptions).

Options:
      --release NAME           Helm-style release name (default: postgres)
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
      --username NAME            Admin role name (default: admin; see
                                'Why not "postgres"?' below)
      --database NAME             Pre-create this logical database at
                                install time (repeatable), owned by
                                --username. Default: none; databases can
                                always be managed later with 'saas
                                postgres database', see 'saas postgres
                                database --help'
      --domain DOMAIN            Certificate identity (CN/SAN; matters
                                for a host client using
                                sslmode=verify-full against a --tls
                                letsencrypt certificate). Defaults to
                                '<release>.postgres.local' with --tls
                                self-signed. With --tls letsencrypt:
                                required, no safe default.
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
      --ingress-class NAME       IngressClass used ONLY by cert-manager's
                                own HTTP-01 ACME solver (default: nginx);
                                PostgreSQL's own wire protocol is never
                                served through an Ingress, it isn't HTTP
      --expose                    Publish PostgreSQL on a host port (kind
                                only, see --host-port). Default: off,
                                since the primary consumers are other
                                SaaS services running inside the cluster
      --no-expose                  Don't publish (default)
      --host-port PORT            Host port to publish on with --expose
                                (kind only; default: 15432, to avoid
                                colliding with a host's own local
                                PostgreSQL on 5432)
  -y, --yes                      Don't ask anything; use the default
                                values without confirmation
      --non-interactive          Same as --yes for the fill-in prompts
  -h, --help                     Show this help

Modes (--mode):
  dev    Single instance (StatefulSet), no HA. Meant for
         --cluster-mode kind.
  prod   CloudNativePG-managed 3-instance Cluster, real automatic
         failover, native TLS integration.

Why not "postgres" as the default admin username? CloudNativePG
(--mode prod) reserves that name for its own internal superuser, whose
password this tool deliberately never sets or manages; 'admin' works
identically and correctly as an ordinary role in both modes, so it's
the default instead. Any other name works too, except 'postgres'.

TLS is always enforced, in both modes: a plain, unencrypted connection
is REJECTED outright (verified live), not just offered as an option.
Self-signed mode gives encryption without hostname/CA verification
(sslmode=require), the same trust level this repo's other "self-
signed" TLS modes already provide elsewhere; not an oversight, a
deliberately matched scope.

Options with no safe default (asked with no suggestion, and DO fail in
--non-interactive if missing, there's no reasonable automatic choice):
  --domain (with --tls letsencrypt), --email (with --tls letsencrypt),
  --dns-token (with --challenge dns01)

Examples:
  saas postgres install
  saas postgres install --release demo --mode dev --database myapp
  saas postgres install --cluster-mode existing --storage-class gp3 \
      --mode prod --tls letsencrypt --challenge http01 \
      --domain postgres.mycompany.com --email me@mycompany.com
  saas postgres install --non-interactive -y
EOF
}

_saas_postgres_install() {
    local release="" namespace="" cluster_mode="kind" kind_name="" kind_workers="0"
    local storage_mode="local-path" storage_class=""
    local mode="dev" username="admin" domain="" tls="self-signed"
    local challenge="" dns_provider="cloudflare" dns_token="" email=""
    local ingress_class="nginx" expose=false host_port="15432"
    local yes=false non_interactive=false
    local -a databases=()

    local release_set=false namespace_set=false cluster_mode_set=false kind_name_set=false
    local kind_workers_set=false storage_mode_set=false storage_class_set=false
    local mode_set=false username_set=false domain_set=false tls_set=false
    local challenge_set=false dns_provider_set=false ingress_class_set=false
    local expose_set=false host_port_set=false

    local args
    args=$(getopt -o yh -l release:,namespace:,cluster-mode:,kind-name:,kind-workers:,storage-mode:,storage-class:,mode:,username:,database:,domain:,tls:,challenge:,dns-provider:,dns-token:,email:,ingress-class:,expose,no-expose,host-port:,yes,non-interactive,help --name saas_postgres_install -- "$@") || {
        _saas_postgres_install_help; return 1
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
            --username)        username="$2"; username_set=true; shift 2 ;;
            --database)        databases+=("$2"); shift 2 ;;
            --domain)          domain="$2"; domain_set=true; shift 2 ;;
            --tls)             tls="$2"; tls_set=true; shift 2 ;;
            --challenge)       challenge="$2"; challenge_set=true; shift 2 ;;
            --dns-provider)    dns_provider="$2"; dns_provider_set=true; shift 2 ;;
            --dns-token)       dns_token="$2"; shift 2 ;;
            --email)           email="$2"; shift 2 ;;
            --ingress-class)   ingress_class="$2"; ingress_class_set=true; shift 2 ;;
            --expose)          expose=true; expose_set=true; shift ;;
            --no-expose)       expose=false; expose_set=true; shift ;;
            --host-port)       host_port="$2"; host_port_set=true; shift 2 ;;
            -y|--yes)          yes=true; shift ;;
            --non-interactive) non_interactive=true; shift ;;
            -h|--help)         _saas_postgres_install_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    $yes && non_interactive=true

    # 'helm' is needed even though dev-mode PostgreSQL itself is plain manifests (no chart):
    # _saas_ensure_certmanager/_saas_ensure_cnpg_operator (lib/common.sh) install their own charts.
    _saas_check_deps kubectl helm jq envsubst || return 1

    local db
    for db in "${databases[@]}"; do
        _saas_postgres_valid_database_name "$db" || {
            _saas_log_err "--database '$db' isn't a valid PostgreSQL identifier (lowercase letters/digits/underscores, starting with a letter or underscore)."
            return 1
        }
    done

    # --- identity (release/namespace) ---
    $release_set || release="$(_saas_prompt "Release name" "postgres" "$non_interactive")"
    [ -n "$release" ] || { _saas_log_err "--release cannot be empty."; return 1; }
    $namespace_set || namespace="$(_saas_prompt "Kubernetes namespace" "$release" "$non_interactive")"

    # --- admin username ---
    if $username_set; then
        _saas_postgres_valid_username "$username" || { _saas_log_err "--username isn't a valid PostgreSQL identifier."; return 1; }
        [ "$username" != "postgres" ] || {
            _saas_log_err "--username cannot be 'postgres': that name is reserved for CloudNativePG's own internal superuser in --mode prod (see 'saas postgres install --help')."
            return 1
        }
    else
        username="$(_saas_prompt_validated "Admin role name" "admin" "$non_interactive" "must be a valid identifier, and not 'postgres'" _saas_postgres_valid_admin_username)" || return 1
    fi

    # --- cluster mode ---
    if $cluster_mode_set; then
        _saas_postgres_valid_cluster_mode "$cluster_mode" || { _saas_log_err "--cluster-mode must be 'kind' or 'existing'."; return 1; }
    else
        cluster_mode="$(_saas_prompt_menu "Cluster mode" "kind" "$non_interactive" kind existing)"
    fi

    if [ "$cluster_mode" = "kind" ]; then
        if $storage_class_set; then
            _saas_log_err "--storage-class only applies with --cluster-mode existing; use --storage-mode for 'kind'."
            return 1
        fi
        $kind_name_set || kind_name="$(_saas_prompt "kind cluster name" "$release" "$non_interactive")"
        $kind_workers_set || kind_workers="$(_saas_prompt_validated "Number of worker nodes for the kind cluster" "$kind_workers" "$non_interactive" "must be an integer >= 0" _saas_postgres_valid_workers)" || return 1
        $storage_mode_set || storage_mode="$(_saas_prompt_menu "kind cluster storage mode" "local-path" "$non_interactive" local-path nfs)"
        [[ "$storage_mode" == "local-path" || "$storage_mode" == "nfs" ]] || {
            _saas_log_err "--storage-mode must be 'local-path' or 'nfs'."; return 1;
        }
        $expose_set || expose="$(_saas_prompt_bool "Publish PostgreSQL on a host port (--expose)" false "$non_interactive")"
        if [ "$expose" = "true" ]; then
            $host_port_set || host_port="$(_saas_prompt_validated "Host port to publish on" "$host_port" "$non_interactive" "must be a port 1-65535" _saas_postgres_valid_hostport)" || return 1
        fi
    else
        if $storage_mode_set; then
            _saas_log_err "--storage-mode only applies with --cluster-mode kind; use --storage-class for an existing cluster."
            return 1
        fi
        if $expose_set && [ "$expose" = "true" ]; then
            _saas_log_err "--expose only applies with --cluster-mode kind; an existing cluster is expected to already have its own external access set up."
            return 1
        fi
        expose=false
        kubectl cluster-info >/dev/null 2>&1 || {
            _saas_log_err "Could not reach the active kubeconfig's cluster (--cluster-mode existing)."
            return 1
        }
    fi

    # --- dev/prod mode ---
    $mode_set || mode="$(_saas_prompt_menu "Install mode" "dev" "$non_interactive" dev prod)"
    _saas_postgres_valid_mode "$mode" || { _saas_log_err "--mode must be 'dev' or 'prod'."; return 1; }
    if [ "$mode" = "prod" ] && [ "$expose" = "true" ]; then
        _saas_log_err "--expose isn't supported yet with --mode prod: CloudNativePG manages its own Services, and this tool doesn't wire a LoadBalancer override for them in this version (see CLAUDE.md)."
        return 1
    fi

    # --- TLS ---
    if $tls_set; then
        _saas_postgres_valid_tls_mode "$tls" || { _saas_log_err "--tls must be 'self-signed' or 'letsencrypt'."; return 1; }
    else
        tls="$(_saas_prompt_menu "TLS type" "self-signed" "$non_interactive" self-signed letsencrypt)"
    fi

    local issuer_name="${release}-postgres-issuer"
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
        _saas_postgres_valid_challenge "$challenge" || { _saas_log_err "--challenge must be 'http01' or 'dns01'."; return 1; }

        if [ "$challenge" = "dns01" ]; then
            $dns_provider_set || dns_provider="$(_saas_prompt "DNS provider" "cloudflare" "$non_interactive")"
            _saas_postgres_valid_dns_provider "$dns_provider" || { _saas_log_err "--dns-provider must be 'cloudflare' (the only cert-manager-native provider wired up here)."; return 1; }
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
            domain="$(_saas_prompt "Domain (certificate identity)" "${release}.postgres.local" "$non_interactive")"
        else
            if $non_interactive || [ ! -t 0 ]; then
                _saas_log_err "--domain is required with --tls letsencrypt (no safe default possible)."
                return 1
            fi
            printf 'Domain for the certificate (required, e.g. postgres.mycompany.com): ' >&2
            read -r domain
            [ -n "$domain" ] || { _saas_log_err "Empty domain."; return 1; }
        fi
    fi

    # --- remaining options, all with a safe default ---
    if [ "$tls" = "letsencrypt" ] && [ "$challenge" = "http01" ]; then
        $ingress_class_set || ingress_class="$(_saas_prompt "IngressClass (cert-manager's HTTP-01 solver only)" "nginx" "$non_interactive")"
    fi

    # --- StorageClass (existing cluster only) ---
    if [ "$cluster_mode" = "existing" ]; then
        storage_class="$(_saas_resolve_storage_class "$storage_class" "$non_interactive")" || return 1
    fi

    # Reuse existing admin password on a re-install against an already-provisioned release, same
    # reasoning as gitlab/vault/minio: the running database's own password is already baked into
    # the persisted data directory, and Kubernetes doesn't restart a pod just because the Secret it
    # reads from changed.
    local admin_password=""
    if _saas_postgres_state_load "$release"; then
        admin_password="$SAAS_POSTGRES_STATE_ADMIN_PASSWORD"
    fi

    _saas_postgres_provision "$release" "$namespace" "$cluster_mode" "$kind_name" "$kind_workers" \
        "$storage_mode" "$storage_class" "$mode" "$username" "$domain" "$tls" "$issuer_name" \
        "$challenge" "$dns_provider" "$dns_token" "$email" "$ingress_class" "$expose" "$host_port" \
        "$admin_password" "${databases[@]}"
}

# _saas_postgres_valid_admin_username VALUE
# Same as _saas_postgres_valid_username, plus the CNPG-reserved-name check, so
# _saas_prompt_validated's retry loop can validate BOTH in one pass when --username wasn't given.
_saas_postgres_valid_admin_username() {
    _saas_postgres_valid_username "$1" && [ "$1" != "postgres" ]
}

# _saas_postgres_provision RELEASE NAMESPACE CLUSTER_MODE KIND_NAME KIND_WORKERS STORAGE_MODE \
#   STORAGE_CLASS MODE USERNAME DOMAIN TLS ISSUER_NAME CHALLENGE DNS_PROVIDER DNS_TOKEN EMAIL \
#   INGRESS_CLASS EXPOSE HOST_PORT ADMIN_PASSWORD [DATABASE...]
#
# Actually provisions everything (cluster, backend, TLS, databases) and persists the state. Shared
# by 'install' and 'up'. ADMIN_PASSWORD, if empty, is generated here (first install); if non-empty
# (reused from saved state), kept as-is so as not to break data already on disk.
_saas_postgres_provision() {
    local release="$1" namespace="$2" cluster_mode="$3" kind_name="$4" kind_workers="$5"
    local storage_mode="$6" storage_class="$7" mode="$8" username="$9" domain="${10}" tls="${11}" issuer_name="${12}"
    local challenge="${13}" dns_provider="${14}" dns_token="${15}" email="${16}" ingress_class="${17}"
    local expose="${18}" host_port="${19}" admin_password="${20}"
    shift 20
    local -a databases=("$@")

    [ -n "$admin_password" ] || admin_password="$(_saas_random_password 32)"

    local databases_csv
    databases_csv="$(IFS=,; echo "${databases[*]}")"

    # Early checkpoint: a retried 'install' over the same --release reuses this password.
    _saas_postgres_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" "MODE=$mode" "USERNAME=$username" \
        "ADMIN_PASSWORD=$admin_password" "STATUS=provisioning"

    if [ "$cluster_mode" = "kind" ]; then
        if _saas_postgres_cluster_exists "$kind_name"; then
            _saas_log_info "The kind cluster '$kind_name' already exists, reusing it."
        else
            _saas_postgres_cluster_create "$kind_name" "$kind_workers" "$storage_mode" true true none || return 1
        fi
        _saas_postgres_cluster_use "$kind_name" || return 1
        storage_class=""
    fi

    _saas_postgres_secrets_apply "$namespace" "$release" "$username" "$admin_password" || return 1

    _saas_log_step "Configuring TLS (cert-manager)…"
    _saas_ensure_certmanager || return 1
    case "$tls" in
        self-signed)
            _saas_postgres_certmanager_issuer_selfsigned "$issuer_name" || return 1
            ;;
        letsencrypt)
            if [ "$challenge" = "http01" ]; then
                _saas_postgres_certmanager_issuer_letsencrypt_http01 "$issuer_name" "$email" "$ingress_class" || return 1
            else
                _saas_postgres_certmanager_issuer_letsencrypt_dns01_cloudflare "$issuer_name" "$email" "$dns_token" || return 1
            fi
            ;;
    esac
    local tls_secret="${release}-postgresql-tls"
    local svc_dns="${release}-postgresql.${namespace}.svc.cluster.local"
    _saas_postgres_certificate_request "$namespace" "${release}-postgresql-cert" "$domain" "$issuer_name" "$tls_secret" "$svc_dns" || return 1

    if [ "$mode" = "prod" ]; then
        _saas_log_step "Deploying PostgreSQL (CloudNativePG, 3-instance HA)…"
        _saas_postgres_prod_apply "$namespace" "$release" "$storage_class" "$username" "$tls_secret" || return 1
    else
        _saas_log_step "Deploying PostgreSQL (single instance)…"
        _saas_postgres_dev_apply "$namespace" "$release" "$storage_class" "$username" "$tls_secret" "$expose" || return 1
    fi

    if [ "$cluster_mode" = "kind" ] && [ "$expose" = "true" ]; then
        _saas_log_step "Publishing PostgreSQL on host port ${host_port}…"
        _saas_postgres_expose "$kind_name" "$namespace" "$release" "$host_port" || \
            _saas_log_warn "Could not expose PostgreSQL. Retry with 'saas postgres doctor $release --fix'."
    fi

    if [ "${#databases[@]}" -gt 0 ]; then
        _saas_log_step "Pre-creating ${#databases[@]} database(s)…"
        local pod db
        pod="$(_saas_postgres_primary_pod "$namespace" "$release" "$mode")"
        for db in "${databases[@]}"; do
            _saas_postgres_database_create_internal "$namespace" "$pod" "$username" "$admin_password" "$release" "$db" || return 1
        done
    fi

    _saas_postgres_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "KIND_NAME=$kind_name" "KIND_WORKERS=$kind_workers" "STORAGE_MODE=$storage_mode" "STORAGE_CLASS=$storage_class" \
        "MODE=$mode" "USERNAME=$username" "DOMAIN=$domain" "TLS=$tls" "ISSUER_NAME=$issuer_name" \
        "CHALLENGE=$challenge" "DNS_PROVIDER=$dns_provider" "EMAIL=$email" "INGRESS_CLASS=$ingress_class" \
        "EXPOSE=$expose" "HOST_PORT=$host_port" "DATABASES=$databases_csv" \
        "ADMIN_PASSWORD=$admin_password" \
        "STATUS=up"

    _saas_log_ok "PostgreSQL '$release' is ready."
    _saas_postgres_credentials "$release"
}

_saas_postgres_up_help() {
    cat <<'EOF'
Usage: saas postgres up [RELEASE] [OPTIONS]

Recreates RELEASE's kind cluster (previously destroyed with 'saas
postgres down', without --purge-storage) and reinstalls PostgreSQL
reusing the state saved from the original install: same admin
password, same domain, same databases re-created (idempotently). Only
applies to installs with --cluster-mode kind.

Options:
  -y, --yes       Don't ask for anything extra
  -h, --help      Show this help

Examples:
  saas postgres up
  saas postgres up demo
EOF
}

_saas_postgres_up() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_postgres_up -- "$@") || { _saas_postgres_up_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_postgres_up_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'. Use 'saas postgres install' first."; return 1; }
    [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'up' only applies to installs with --cluster-mode kind."; return 1; }

    local -a databases=()
    if [ -n "${SAAS_POSTGRES_STATE_DATABASES:-}" ]; then
        IFS=',' read -r -a databases <<< "$SAAS_POSTGRES_STATE_DATABASES"
    fi

    _saas_postgres_provision "$SAAS_POSTGRES_STATE_RELEASE" "$SAAS_POSTGRES_STATE_NAMESPACE" "$SAAS_POSTGRES_STATE_CLUSTER_MODE" \
        "$SAAS_POSTGRES_STATE_KIND_NAME" "$SAAS_POSTGRES_STATE_KIND_WORKERS" "$SAAS_POSTGRES_STATE_STORAGE_MODE" "" \
        "$SAAS_POSTGRES_STATE_MODE" "$SAAS_POSTGRES_STATE_USERNAME" "$SAAS_POSTGRES_STATE_DOMAIN" "$SAAS_POSTGRES_STATE_TLS" \
        "$SAAS_POSTGRES_STATE_ISSUER_NAME" "$SAAS_POSTGRES_STATE_CHALLENGE" "$SAAS_POSTGRES_STATE_DNS_PROVIDER" "" \
        "$SAAS_POSTGRES_STATE_EMAIL" "$SAAS_POSTGRES_STATE_INGRESS_CLASS" "${SAAS_POSTGRES_STATE_EXPOSE:-false}" "$SAAS_POSTGRES_STATE_HOST_PORT" \
        "$SAAS_POSTGRES_STATE_ADMIN_PASSWORD" "${databases[@]}"
}

_saas_postgres_down_help() {
    cat <<'EOF'
Usage: saas postgres down [RELEASE] [OPTIONS]

Destroys RELEASE's kind cluster (host CPU/RAM usage drops to zero)
while preserving the data in the host's storage directory. 'saas
postgres up' recovers it when recreating the cluster. Only applies to
installs with --cluster-mode kind.

Options:
  -y, --yes       Don't ask for confirmation
  -h, --help      Show this help

Examples:
  saas postgres down
  saas postgres down demo -y
EOF
}

_saas_postgres_down() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_postgres_down -- "$@") || { _saas_postgres_down_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_postgres_down_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'down' only applies to installs with --cluster-mode kind."; return 1; }

    echo "This will destroy the kind cluster '$SAAS_POSTGRES_STATE_KIND_NAME' (data is preserved on the host)." >&2
    _saas_confirm "$yes" || return 1

    _saas_postgres_cluster_delete "$SAAS_POSTGRES_STATE_KIND_NAME" false || return 1
    _saas_postgres_state_save_key "$release" "STATUS" "down"
    _saas_log_ok "kind cluster '$SAAS_POSTGRES_STATE_KIND_NAME' destroyed. Data preserved. Use 'saas postgres up $release' to bring it back up."
}

_saas_postgres_delete_help() {
    cat <<'EOF'
Usage: saas postgres delete [RELEASE] [OPTIONS]

Full uninstall: removes PostgreSQL, its namespace, and (in
--cluster-mode kind) the cluster itself. Also removes the saved
state.

Options:
      --purge-storage   Also removes the data persisted on the host
                        (--cluster-mode kind only). Irreversible
  -y, --yes             Don't ask for confirmation
  -h, --help             Show this help

Examples:
  saas postgres delete
  saas postgres delete demo --purge-storage -y
EOF
}

_saas_postgres_delete() {
    local release="" yes=false purge=false
    local args
    args=$(getopt -o yh -l purge-storage,yes,help --name saas_postgres_delete -- "$@") || { _saas_postgres_delete_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --purge-storage) purge=true; shift ;;
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_postgres_delete_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "This will completely remove the PostgreSQL install '$release'$($purge && echo ' (including the data, --purge-storage)')." >&2
    _saas_confirm "$yes" || return 1

    if [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ]; then
        _saas_postgres_cluster_delete "$SAAS_POSTGRES_STATE_KIND_NAME" "$purge" || return 1
    else
        kubectl delete clusterissuer "$SAAS_POSTGRES_STATE_ISSUER_NAME" --ignore-not-found >/dev/null 2>&1
        if [ "$SAAS_POSTGRES_STATE_MODE" = "prod" ]; then
            _saas_postgres_prod_delete "$SAAS_POSTGRES_STATE_NAMESPACE" "$SAAS_POSTGRES_STATE_RELEASE"
        else
            _saas_postgres_dev_delete "$SAAS_POSTGRES_STATE_NAMESPACE" "$SAAS_POSTGRES_STATE_RELEASE"
        fi
        $purge && kubectl delete namespace "$SAAS_POSTGRES_STATE_NAMESPACE" --ignore-not-found >/dev/null 2>&1
    fi

    _saas_postgres_state_delete "$release"
    _saas_log_ok "Install '$release' removed."
}

_saas_postgres_status_help() {
    cat <<'EOF'
Usage: saas postgres status [RELEASE] [OPTIONS]

Shows RELEASE's saved state and, if the cluster is reachable, the real
status of its pods.

Options:
  -h, --help   Show this help
EOF
}

_saas_postgres_status() {
    local release=""
    case "${1:-}" in -h|--help) _saas_postgres_status_help; return 0 ;; esac
    release="${1:-$(_saas_postgres_suggest_release)}"

    _saas_postgres_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "Release:        $SAAS_POSTGRES_STATE_RELEASE"
    echo "Namespace:      $SAAS_POSTGRES_STATE_NAMESPACE"
    echo "Cluster:        $SAAS_POSTGRES_STATE_CLUSTER_MODE${SAAS_POSTGRES_STATE_KIND_NAME:+ ($SAAS_POSTGRES_STATE_KIND_NAME)}"
    echo "Mode:           $SAAS_POSTGRES_STATE_MODE"
    echo "Admin user:     $SAAS_POSTGRES_STATE_USERNAME"
    echo "Domain:         $SAAS_POSTGRES_STATE_DOMAIN"
    echo "TLS:            $SAAS_POSTGRES_STATE_TLS"
    echo "Exposed:        ${SAAS_POSTGRES_STATE_EXPOSE:-false}${SAAS_POSTGRES_STATE_HOST_PORT:+ (port $SAAS_POSTGRES_STATE_HOST_PORT)}"
    echo "Databases:      ${SAAS_POSTGRES_STATE_DATABASES:-(none pre-created)}"
    echo "Saved status:   $SAAS_POSTGRES_STATE_STATUS"

    if [ "$SAAS_POSTGRES_STATE_CLUSTER_MODE" = "kind" ] && ! _saas_postgres_cluster_exists "$SAAS_POSTGRES_STATE_KIND_NAME" 2>/dev/null; then
        echo
        echo "The kind cluster doesn't currently exist (a 'saas postgres down' pending 'up'?)."
        return 0
    fi

    if kubectl -n "$SAAS_POSTGRES_STATE_NAMESPACE" get pods >/dev/null 2>&1; then
        echo
        kubectl -n "$SAAS_POSTGRES_STATE_NAMESPACE" get pods
    fi
}
