# --- saas gitlab install|up|down|delete|status
#
# 'install' resolves every parameter (flags > interactive prompts > sensible defaults) and delegates the actual provisioning to _saas_gitlab_provision, the same function 'up' uses after reloading the parameters from the saved state (services/gitlab/lib/state.sh), so there's no second copy of the provisioning logic.

_saas_gitlab_valid_mode()   { [[ "$1" == "dev" || "$1" == "prod" ]]; }
_saas_gitlab_valid_bool()   { [[ "$1" == "true" || "$1" == "false" ]]; }
_saas_gitlab_valid_hostport() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_saas_gitlab_valid_workers()  { [[ "$1" =~ ^[0-9]+$ ]]; }
_saas_gitlab_valid_nonempty() { [ -n "$1" ]; }
_saas_gitlab_valid_pages_url_mode() { [[ "$1" == "path" || "$1" == "subdomain" ]]; }

# _saas_gitlab_valid_pages_subdomain_tls PAGES_URL_MODE TLS CHALLENGE
# A wildcard *.pages.<domain> certificate needs no external validation at all with
# --tls self-signed (the ClusterIssuer signs it locally, no CA involved), but with
# --tls letsencrypt it can only be obtained via --challenge dns01 (ACME wildcard rule).
_saas_gitlab_valid_pages_subdomain_tls() {
    local pages_url_mode="$1" tls="$2" challenge="$3"
    [ "$pages_url_mode" != "subdomain" ] || [ "$tls" = "self-signed" ] || [ "$challenge" = "dns01" ]
}

_saas_gitlab_install_help() {
    cat <<'EOF'
Usage: saas gitlab install [OPTIONS]

Installs (or updates in place, it's idempotent) self-hosted GitLab on
Kubernetes: a local kind cluster or an existing cluster via kubeconfig,
its own PostgreSQL/Redis/MinIO (the official chart no longer bundles
them), cert-manager + TLS, and a GitLab Runner registered and ready for CI.

Any option that's omitted (except -y/--yes or --non-interactive) is asked
interactively, suggesting the default value in brackets; without a tty or
with --non-interactive that default is used silently, warning if it had
to pick between several ambiguous options (never aborts over that; see
'Options with no safe default' below).

Options:
      --release NAME           Helm release name (default: gitlab)
      --namespace NS           Kubernetes namespace (default: same as
                                --release)
      --cluster-mode MODE      kind (default) or existing
      --kind-name NAME         Name of the kind cluster (kind only;
                                default: same as --release)
      --kind-workers N         Number of worker nodes in the kind cluster
                                (kind only; default: 0)
      --storage-mode MODE      local-path (default) or nfs; only with
                                --cluster-mode kind, passed through to
                                kind_cluster
      --storage-class NAME     StorageClass to use; only with
                                --cluster-mode existing (default: the
                                cluster's default StorageClass is
                                detected)
      --mode MODE               dev (default) or prod, see 'Modes'
      --version VERSION         Version of the gitlab/gitlab chart, or
                                'latest' (default). See 'saas gitlab
                                versions'.
      --domain DOMAIN            Domain to serve GitLab on. Defaults to
                                '<release>.gitlab.local' with --tls
                                self-signed. With --tls letsencrypt:
                                required, no safe default possible.
      --tls MODE                 self-signed (default in --mode dev) or
                                letsencrypt (required in --mode prod
                                unless --force-self-signed-prod)
      --force-self-signed-prod  Allows --mode prod with --tls self-signed
                                (with a warning); evaluation/demo only
      --challenge TYPE           http01 or dns01; only with --tls
                                letsencrypt. Default: dns01 with
                                --cluster-mode kind (no public
                                reachability), http01 with --cluster-mode
                                existing.
      --dns-provider PROVIDER    cloudflare (default) or duckdns; only
                                with --challenge dns01. duckdns installs
                                a third-party cert-manager webhook (the
                                one deliberate exception in this repo,
                                since DuckDNS has no native cert-manager
                                support); cloudflare is native to
                                cert-manager, no extra component
      --dns-token TOKEN          DNS provider API token (cloudflare) or
                                account token (duckdns); required with
                                --challenge dns01, no safe default
      --email EMAIL              Let's Encrypt account email, required
                                with --tls letsencrypt, no safe default
      --ingress-class NAME       IngressClass to use (default: nginx)
      --ssh-host-port PORT       Host port mapped to GitLab's internal
                                SSH (kind only; default: 2222). Doesn't
                                touch the host's real port 22
      --runner                   Deploy and register GitLab Runner
                                (default)
      --no-runner                 Don't deploy GitLab Runner
      --registry                  Enable the Container Registry
                                (default)
      --no-registry                Disable the Container Registry
      --pages                      Enable GitLab Pages (its own
                                subdomain, path-based project URLs so
                                it works with any TLS challenge type)
      --no-pages                   Disable GitLab Pages (default)
      --pages-url-mode MODE       path (default) or subdomain, only with
                                --pages. 'subdomain' gives Pages its
                                native per-namespace URLs
                                (<namespace>.pages.<domain>/<project>)
                                instead of path-based ones
                                (pages.<domain>/<group>/<project>/), at
                                the cost of needing a wildcard
                                *.pages.<domain> certificate: only
                                possible with --tls self-signed (signs
                                it locally, no external validation) or
                                --tls letsencrypt --challenge dns01 (the
                                only ACME challenge that can prove
                                ownership of a wildcard name)
  -y, --yes                      Don't ask anything; use the default
                                values without confirmation
      --non-interactive          Same as --yes for the fill-in prompts
  -h, --help                     Show this help

Modes (--mode):
  dev    1 replica per component, reduced resources, GitLab
         Pages/KAS/Prometheus disabled (Container Registry follows
         --registry/--no-registry), self-signed TLS by default. Meant
         for --cluster-mode kind. PostgreSQL/Redis/MinIO: our own
         single-instance stack, no HA, deliberately unchanged, this
         mode is meant to be disposable and minimal.
  prod   Replicas/resources aligned to the chart's official baseline
         (~8 vCPU/16GB), Let's Encrypt TLS required unless
         --force-self-signed-prod. PostgreSQL/Redis/MinIO now run with
         real HA (CloudNativePG, Redis Sentinel via redis-operator,
         4-node distributed MinIO) unconditionally, not an opt-in
         flag: "prod" means production-grade datastores. One known
         trade-off: Sentinel-port auth is left disabled, pending an
         upstream fix, while the Redis data connection itself stays
         fully password-protected.

Options with no safe default (asked with no suggestion, and DO fail in
--non-interactive if missing, there's no reasonable automatic choice):
  --domain (with --tls letsencrypt), --email (with --tls letsencrypt),
  --dns-token (with --challenge dns01)

Examples:
  saas gitlab install
  saas gitlab install --release demo --mode dev --storage-mode nfs
  saas gitlab install --cluster-mode existing --storage-class gp3 \
      --mode prod --tls letsencrypt --challenge http01 \
      --domain gitlab.mycompany.com --email me@mycompany.com
  saas gitlab install --cluster-mode kind --mode prod \
      --tls letsencrypt --challenge dns01 --dns-provider cloudflare \
      --domain gitlab.mycompany.com --dns-token "$CF_TOKEN" \
      --email me@mycompany.com
  saas gitlab install --non-interactive -y
EOF
}

_saas_gitlab_install() {
    local release="" namespace="" cluster_mode="kind" kind_name="" kind_workers="0"
    local storage_mode="local-path" storage_class=""
    local mode="dev" version="latest" domain="" tls="" force_self_signed_prod=false
    local challenge="" dns_provider="cloudflare" dns_token="" email=""
    local ingress_class="nginx" ssh_host_port="2222" runner_enabled=true
    local registry_enabled=true pages_enabled=false pages_url_mode="path"
    local yes=false non_interactive=false

    local release_set=false namespace_set=false cluster_mode_set=false kind_name_set=false
    local kind_workers_set=false storage_mode_set=false storage_class_set=false
    local mode_set=false version_set=false domain_set=false tls_set=false
    local challenge_set=false dns_provider_set=false ingress_class_set=false
    local ssh_host_port_set=false runner_set=false registry_set=false pages_set=false
    local pages_url_mode_set=false

    local args
    args=$(getopt -o yh -l release:,namespace:,cluster-mode:,kind-name:,kind-workers:,storage-mode:,storage-class:,mode:,version:,domain:,tls:,force-self-signed-prod,challenge:,dns-provider:,dns-token:,email:,ingress-class:,ssh-host-port:,runner,no-runner,registry,no-registry,pages,no-pages,pages-url-mode:,yes,non-interactive,help --name saas_gitlab_install -- "$@") || {
        _saas_gitlab_install_help; return 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release)            release="$2"; release_set=true; shift 2 ;;
            --namespace)          namespace="$2"; namespace_set=true; shift 2 ;;
            --cluster-mode)       cluster_mode="$2"; cluster_mode_set=true; shift 2 ;;
            --kind-name)          kind_name="$2"; kind_name_set=true; shift 2 ;;
            --kind-workers)       kind_workers="$2"; kind_workers_set=true; shift 2 ;;
            --storage-mode)       storage_mode="$2"; storage_mode_set=true; shift 2 ;;
            --storage-class)      storage_class="$2"; storage_class_set=true; shift 2 ;;
            --mode)                mode="$2"; mode_set=true; shift 2 ;;
            --version)             version="$2"; version_set=true; shift 2 ;;
            --domain)               domain="$2"; domain_set=true; shift 2 ;;
            --tls)                  tls="$2"; tls_set=true; shift 2 ;;
            --force-self-signed-prod) force_self_signed_prod=true; shift ;;
            --challenge)             challenge="$2"; challenge_set=true; shift 2 ;;
            --dns-provider)          dns_provider="$2"; dns_provider_set=true; shift 2 ;;
            --dns-token)             dns_token="$2"; shift 2 ;;
            --email)                 email="$2"; shift 2 ;;
            --ingress-class)         ingress_class="$2"; ingress_class_set=true; shift 2 ;;
            --ssh-host-port)         ssh_host_port="$2"; ssh_host_port_set=true; shift 2 ;;
            --runner)                runner_enabled=true; runner_set=true; shift ;;
            --no-runner)             runner_enabled=false; runner_set=true; shift ;;
            --registry)              registry_enabled=true; registry_set=true; shift ;;
            --no-registry)           registry_enabled=false; registry_set=true; shift ;;
            --pages)                 pages_enabled=true; pages_set=true; shift ;;
            --no-pages)              pages_enabled=false; pages_set=true; shift ;;
            --pages-url-mode)        pages_url_mode="$2"; pages_url_mode_set=true; shift 2 ;;
            -y|--yes)                yes=true; shift ;;
            --non-interactive)       non_interactive=true; shift ;;
            -h|--help)               _saas_gitlab_install_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    $yes && non_interactive=true

    _saas_check_deps kubectl helm jq envsubst || return 1

    # --- identity (release/namespace) ---
    $release_set || release="$(_saas_prompt "Release name" "gitlab" "$non_interactive")"
    [ -n "$release" ] || { _saas_log_err "--release cannot be empty."; return 1; }
    $namespace_set || namespace="$(_saas_prompt "Kubernetes namespace" "$release" "$non_interactive")"

    # --- cluster mode ---
    if $cluster_mode_set; then
        _saas_gitlab_valid_cluster_mode "$cluster_mode" || { _saas_log_err "--cluster-mode must be 'kind' or 'existing'."; return 1; }
    else
        cluster_mode="$(_saas_prompt_menu "Cluster mode" "kind" "$non_interactive" kind existing)"
    fi

    if [ "$cluster_mode" = "kind" ]; then
        if $storage_class_set; then
            _saas_log_err "--storage-class only applies with --cluster-mode existing; use --storage-mode for 'kind'."
            return 1
        fi
        $kind_name_set || kind_name="$(_saas_prompt "kind cluster name" "$release" "$non_interactive")"
        $kind_workers_set || kind_workers="$(_saas_prompt_validated "Number of worker nodes for the kind cluster" "$kind_workers" "$non_interactive" "must be an integer >= 0" _saas_gitlab_valid_workers)" || return 1
        $storage_mode_set || storage_mode="$(_saas_prompt_menu "kind cluster storage mode" "local-path" "$non_interactive" local-path nfs)"
        [[ "$storage_mode" == "local-path" || "$storage_mode" == "nfs" ]] || {
            _saas_log_err "--storage-mode must be 'local-path' or 'nfs'."; return 1;
        }
    else
        if $storage_mode_set; then
            _saas_log_err "--storage-mode only applies with --cluster-mode kind; use --storage-class for an existing cluster."
            return 1
        fi
        _saas_check_deps kubectl >/dev/null
        kubectl cluster-info >/dev/null 2>&1 || {
            _saas_log_err "Could not reach the active kubeconfig's cluster (--cluster-mode existing)."
            return 1
        }
    fi

    # --- dev/prod mode ---
    $mode_set || mode="$(_saas_prompt_menu "Install mode" "dev" "$non_interactive" dev prod)"
    _saas_gitlab_valid_mode "$mode" || { _saas_log_err "--mode must be 'dev' or 'prod'."; return 1; }

    # --- chart version ---
    version="$(_saas_gitlab_version_resolve "$version")" || return 1

    # --- TLS ---
    if ! $tls_set; then
        local tls_default="self-signed"
        [ "$mode" = "prod" ] && tls_default="letsencrypt"
        tls="$(_saas_prompt_menu "TLS type" "$tls_default" "$non_interactive" self-signed letsencrypt)"
    fi
    _saas_gitlab_valid_tls_mode "$tls" || { _saas_log_err "--tls must be 'self-signed' or 'letsencrypt'."; return 1; }
    if [ "$mode" = "prod" ] && [ "$tls" = "self-signed" ] && ! $force_self_signed_prod; then
        _saas_log_err "--mode prod requires --tls letsencrypt (self-signed in production isn't real trusted TLS)."
        _saas_log_err "If this is just an evaluation/demo, repeat with --force-self-signed-prod."
        return 1
    fi

    local issuer_name="${release}-issuer"
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
        _saas_gitlab_valid_challenge "$challenge" || { _saas_log_err "--challenge must be 'http01' or 'dns01'."; return 1; }

        if [ "$challenge" = "dns01" ]; then
            $dns_provider_set || dns_provider="$(_saas_prompt_menu "DNS provider" "cloudflare" "$non_interactive" cloudflare duckdns)"
            _saas_gitlab_valid_dns_provider "$dns_provider" || { _saas_log_err "--dns-provider must be 'cloudflare' or 'duckdns'."; return 1; }
            [ -n "$dns_token" ] || {
                if $non_interactive || [ ! -t 0 ]; then
                    _saas_log_err "--dns-token is required with --challenge dns01 (no safe default possible)."
                    return 1
                fi
                local token_label="Cloudflare API token (required): "
                [ "$dns_provider" = "duckdns" ] && token_label="DuckDNS account token (required): "
                printf '%s' "$token_label" >&2
                read -r dns_token
                [ -n "$dns_token" ] || { _saas_log_err "Empty token."; return 1; }
            }
        fi
    fi

    # --- Pages enabled? + Pages URL mode (resolved before '--- domain ---' below, so the
    # domain prompt's suggested default can take the Pages URL mode into account) ---
    $pages_set || pages_enabled="$(_saas_prompt_bool "Enable GitLab Pages" false "$non_interactive")"

    if [ "$pages_enabled" = "true" ]; then
        if $pages_url_mode_set; then
            _saas_gitlab_valid_pages_url_mode "$pages_url_mode" || { _saas_log_err "--pages-url-mode must be 'path' or 'subdomain'."; return 1; }
        else
            local -a pages_url_mode_options=("path")
            { [ "$tls" = "self-signed" ] || [ "$challenge" = "dns01" ]; } && pages_url_mode_options+=("subdomain")
            pages_url_mode="$(_saas_prompt_menu "GitLab Pages URL mode" "path" "$non_interactive" "${pages_url_mode_options[@]}")"
        fi
        _saas_gitlab_valid_pages_subdomain_tls "$pages_url_mode" "$tls" "$challenge" || {
            _saas_log_err "--pages-url-mode subdomain needs either --tls self-signed (no external validation needed) or --tls letsencrypt --challenge dns01 (a wildcard *.pages.<domain> certificate from a real CA can only be issued via a DNS-01 challenge)."
            return 1
        }
    elif $pages_url_mode_set; then
        _saas_log_err "--pages-url-mode only applies with --pages."
        return 1
    fi

    # --- domain ---
    if [ -z "$domain" ]; then
        if [ "$tls" = "self-signed" ]; then
            local domain_default="${release}.gitlab.local"
            if [ "$pages_enabled" = "true" ] && [ "$pages_url_mode" = "subdomain" ] && [ "$cluster_mode" = "kind" ]; then
                # A wildcard Pages hostname needs to resolve to this host's own address from
                # the user's browser too (not just inside the cluster, see
                # _saas_gitlab_cluster_patch_coredns_pages_wildcard). A '<ip>.nip.io' name
                # resolves that automatically for any subdomain, with zero setup, since kind
                # exposes GitLab on 127.0.0.1 via hostPort (cluster.sh). Self-signed only:
                # nip.io can't help prove domain ownership to a real CA (--tls letsencrypt),
                # so this default doesn't apply there.
                domain_default="127.0.0.1.nip.io"
            fi
            domain="$(_saas_prompt "Domain" "$domain_default" "$non_interactive")"
        else
            if $non_interactive || [ ! -t 0 ]; then
                _saas_log_err "--domain is required with --tls letsencrypt (no safe default possible)."
                return 1
            fi
            printf 'Domain to serve GitLab on (required, e.g. gitlab.mycompany.com): ' >&2
            read -r domain
            [ -n "$domain" ] || { _saas_log_err "Empty domain."; return 1; }
        fi
    fi

    # --- remaining options, all with a safe default ---
    $ingress_class_set || ingress_class="$(_saas_prompt "IngressClass" "nginx" "$non_interactive")"
    if [ "$cluster_mode" = "kind" ]; then
        $ssh_host_port_set || ssh_host_port="$(_saas_prompt_validated "Host port for GitLab SSH" "$ssh_host_port" "$non_interactive" "must be a port 1-65535" _saas_gitlab_valid_hostport)" || return 1
    fi
    $runner_set || runner_enabled="$(_saas_prompt_bool "Deploy and register GitLab Runner" true "$non_interactive")"
    $registry_set || registry_enabled="$(_saas_prompt_bool "Enable the Container Registry" true "$non_interactive")"

    # --- StorageClass (existing cluster only) ---
    if [ "$cluster_mode" = "existing" ]; then
        storage_class="$(_saas_gitlab_resolve_storage_class "$storage_class" "$non_interactive")" || return 1
    fi

    # Reuse existing credentials on a re-install against an already-provisioned release: the
    # chart's Secrets would otherwise be overwritten with fresh random values while the already-
    # running PostgreSQL/MinIO/Redis pods keep their original ones baked into their own env vars
    # (Kubernetes doesn't restart a pod just because the Secret it reads from changed), breaking
    # auth against those datastores. Mirrors what "up"'s own call site below already does;
    # "install" was the one path that skipped this.
    local psql_password="" minio_user="" minio_password="" root_password="" redis_password=""
    if _saas_gitlab_state_load "$release"; then
        psql_password="$SAAS_GITLAB_STATE_PSQL_PASSWORD"
        minio_user="$SAAS_GITLAB_STATE_MINIO_ROOT_USER"
        minio_password="$SAAS_GITLAB_STATE_MINIO_ROOT_PASSWORD"
        root_password="$SAAS_GITLAB_STATE_ROOT_PASSWORD"
        redis_password="$SAAS_GITLAB_STATE_REDIS_PASSWORD"
    fi

    _saas_gitlab_provision "$release" "$namespace" "$cluster_mode" "$kind_name" "$kind_workers" \
        "$storage_mode" "$storage_class" "$mode" "$version" "$domain" "$tls" "$issuer_name" \
        "$challenge" "$dns_provider" "$dns_token" "$email" "$ingress_class" "$ssh_host_port" \
        "$runner_enabled" "$registry_enabled" "$pages_enabled" "$pages_url_mode" \
        "$psql_password" "$minio_user" "$minio_password" "$root_password" "$redis_password"
}

# _saas_gitlab_provision RELEASE NAMESPACE CLUSTER_MODE KIND_NAME KIND_WORKERS \
#   STORAGE_MODE STORAGE_CLASS MODE VERSION DOMAIN TLS ISSUER_NAME \
#   CHALLENGE DNS_PROVIDER DNS_TOKEN EMAIL INGRESS_CLASS SSH_HOST_PORT \
#   RUNNER_ENABLED REGISTRY_ENABLED PAGES_ENABLED PAGES_URL_MODE \
#   PSQL_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD ROOT_PASSWORD REDIS_PASSWORD
#
# Actually provisions everything (cluster, datastore, TLS, chart, runner, ssh) and persists the state. The last five credential parameters, if empty, are generated here (first install); if non-empty (called from 'up', reusing the saved state), they're reused as-is so as not to break data already persisted on disk.
#
# ROOT_PASSWORD deserves an explanation: GitLab only sets the initial 'root' password in the database the very first time it boots with no admin user yet. After 'down'/'up' the database persists (with that password already baked in) but the Secret holding it does NOT. If the chart were left to generate a new random one on every reinstall, the Secret would no longer match the database's real password. That's why we generate and persist it ourselves (same as PSQL_PASSWORD and the MinIO credentials) and pass it to the chart via global.initialRootPassword; the chart is never left to invent it on its own.
#
# REDIS_PASSWORD is only ever used in --mode prod (real HA Redis via redis-operator, password-protected); --mode dev keeps its always-password-less single-instance Redis (see datastore.sh). A disposable, ClusterIP-only local cluster gains no real security from a password, and dev is deliberately out of scope for the HA/security hardening this parameter exists for.

# _saas_gitlab_issue_letsencrypt_dns01 ISSUER_NAME EMAIL TOKEN PROVIDER
# Small dispatch, pulled out of _saas_gitlab_provision so it's unit-testable on its own (stub the two
# issuer functions and assert the right one gets called for each PROVIDER).
_saas_gitlab_issue_letsencrypt_dns01() {
    local issuer_name="$1" email="$2" token="$3" provider="$4"
    case "$provider" in
        cloudflare) _saas_gitlab_certmanager_issuer_letsencrypt_dns01_cloudflare "$issuer_name" "$email" "$token" ;;
        duckdns)    _saas_gitlab_certmanager_issuer_letsencrypt_dns01_duckdns "$issuer_name" "$email" "$token" ;;
        *) _saas_log_err "Unknown DNS-01 provider: '$provider'."; return 1 ;;
    esac
}

# _saas_gitlab_render_values_layer SRC DOMAIN RELEASE NAMESPACE INGRESS_CLASS TLS_SECRET [PAGES_NAMESPACE_IN_PATH]
# Renders one values template (envsubst) into a fresh temp file, printing its path on stdout. Several of these get layered as successive '-f' arguments to 'helm upgrade --install' (see _saas_gitlab_provision): base mode overlay, then optional datastore-ha/registry/pages fragments, in that order, so a later one's keys win over an earlier one's on overlap. PAGES_NAMESPACE_IN_PATH defaults to "true" (its value only matters to the pages.yaml.tpl layer; every other caller/template ignores it).
_saas_gitlab_render_values_layer() {
    local src="$1" domain="$2" release="$3" namespace="$4" ingress_class="$5" tls_secret="$6" pages_namespace_in_path="${7:-true}"
    local out
    out="$(mktemp "${TMPDIR:-/tmp}/saas-gitlab-values-XXXXXX.yaml")" || return 1
    SAAS_DOMAIN="$domain" SAAS_RELEASE="$release" SAAS_NAMESPACE="$namespace" \
        SAAS_INGRESS_CLASS="$ingress_class" SAAS_TLS_SECRET="$tls_secret" \
        SAAS_PAGES_NAMESPACE_IN_PATH="$pages_namespace_in_path" \
        envsubst '${SAAS_DOMAIN} ${SAAS_RELEASE} ${SAAS_NAMESPACE} ${SAAS_INGRESS_CLASS} ${SAAS_TLS_SECRET} ${SAAS_PAGES_NAMESPACE_IN_PATH}' \
        < "$src" > "$out" || return 1
    echo "$out"
}

_saas_gitlab_provision() {
    local release="$1" namespace="$2" cluster_mode="$3" kind_name="$4" kind_workers="$5"
    local storage_mode="$6" storage_class="$7" mode="$8" version="$9" domain="${10}" tls="${11}" issuer_name="${12}"
    local challenge="${13}" dns_provider="${14}" dns_token="${15}" email="${16}" ingress_class="${17}" ssh_host_port="${18}"
    local runner_enabled="${19}" registry_enabled="${20}" pages_enabled="${21}" pages_url_mode="${22}"
    local psql_password="${23}" minio_user="${24}" minio_password="${25}" root_password="${26}" redis_password="${27}"

    [ -n "$psql_password" ] || psql_password="$(_saas_random_password 32)"
    [ -n "$minio_user" ]    || minio_user="gitlab-minio"
    [ -n "$minio_password" ] || minio_password="$(_saas_random_password 32)"
    [ -n "$root_password" ] || root_password="$(_saas_random_password 24)"
    [ -n "$redis_password" ] || redis_password="$(_saas_random_password 32)"

    # Early checkpoint: if something fails further down, a retried 'install' over the same --release reuses these credentials instead of generating new ones that would no longer match data that already made it to disk.
    _saas_gitlab_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "PSQL_PASSWORD=$psql_password" "MINIO_ROOT_USER=$minio_user" "MINIO_ROOT_PASSWORD=$minio_password" \
        "ROOT_PASSWORD=$root_password" "REDIS_PASSWORD=$redis_password" \
        "STATUS=provisioning"

    local -a extra_sans=()
    [ "$registry_enabled" = "true" ] && extra_sans+=("registry.${domain}")
    [ "$pages_enabled" = "true" ] && extra_sans+=("pages.${domain}")

    local pages_subdomain_wildcard=false
    [ "$pages_enabled" = "true" ] && [ "$pages_url_mode" = "subdomain" ] && pages_subdomain_wildcard=true

    if [ "$cluster_mode" = "kind" ]; then
        if _saas_gitlab_cluster_exists "$kind_name"; then
            _saas_log_info "The kind cluster '$kind_name' already exists, reusing it."
        else
            _saas_gitlab_cluster_create "$kind_name" "$kind_workers" "$storage_mode" true true || return 1
        fi
        _saas_gitlab_cluster_use "$kind_name" || return 1
        storage_class=""
        _saas_gitlab_cluster_patch_coredns "$domain" "${extra_sans[@]}"
        _saas_gitlab_cluster_patch_coredns_pages_wildcard "$domain" "$pages_subdomain_wildcard"
    fi

    if [ "$mode" = "prod" ]; then
        _saas_log_step "Deploying HA PostgreSQL/Redis/MinIO…"
        _saas_gitlab_datastore_ha_apply "$namespace" "$release" "$storage_class" \
            "$psql_password" "$minio_user" "$minio_password" "$redis_password" || return 1
    else
        _saas_log_step "Deploying our own PostgreSQL/Redis/MinIO…"
        _saas_gitlab_datastore_apply "$namespace" "$release" "$storage_class" \
            "$psql_password" "$minio_user" "$minio_password" || return 1
    fi

    _saas_log_step "Configuring TLS (cert-manager)…"
    _saas_gitlab_certmanager_ensure || return 1
    case "$tls" in
        self-signed)
            _saas_gitlab_certmanager_issuer_selfsigned "$issuer_name" || return 1
            ;;
        letsencrypt)
            if [ "$challenge" = "http01" ]; then
                _saas_gitlab_certmanager_issuer_letsencrypt_http01 "$issuer_name" "$email" "$ingress_class" || return 1
            else
                _saas_gitlab_issue_letsencrypt_dns01 "$issuer_name" "$email" "$dns_token" "$dns_provider" || return 1
            fi
            ;;
    esac
    local tls_secret="${release}-gitlab-tls"
    _saas_gitlab_certificate_request "$namespace" "${release}-gitlab-cert" "$domain" "$issuer_name" "$tls_secret" "${extra_sans[@]}" || return 1

    local pages_wildcard_tls_secret="${release}-gitlab-pages-wildcard-tls"
    if [ "$pages_subdomain_wildcard" = "true" ]; then
        _saas_gitlab_certificate_request "$namespace" "${release}-gitlab-pages-wildcard-cert" \
            "*.pages.${domain}" "$issuer_name" "$pages_wildcard_tls_secret" || return 1
    fi

    kubectl -n "$namespace" create secret generic "${release}-gitlab-initial-root-password" \
        --from-literal=password="$root_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    _saas_log_step "Installing GitLab (chart gitlab/gitlab @ ${version}), this can take several minutes…"
    _saas_gitlab_helm_repo_ensure || return 1
    local tpl_file="$_SAAS_GITLAB_DIR/values/${mode}.yaml.tpl"
    [ -f "$tpl_file" ] || { _saas_log_err "The values template '$tpl_file' doesn't exist."; return 1; }

    local -a rendered_files=() value_files=()
    local layer

    layer="$(_saas_gitlab_render_values_layer "$tpl_file" "$domain" "$release" "$namespace" "$ingress_class" "$tls_secret")" || { rm -f "${rendered_files[@]}"; return 1; }
    rendered_files+=("$layer"); value_files+=(-f "$layer")
    if [ "$mode" = "prod" ]; then
        layer="$(_saas_gitlab_render_values_layer "$_SAAS_GITLAB_DIR/values/datastore-ha.yaml.tpl" "$domain" "$release" "$namespace" "$ingress_class" "$tls_secret")" || { rm -f "${rendered_files[@]}"; return 1; }
        rendered_files+=("$layer"); value_files+=(-f "$layer")
    fi
    if [ "$registry_enabled" = "true" ]; then
        layer="$(_saas_gitlab_render_values_layer "$_SAAS_GITLAB_DIR/values/registry.yaml.tpl" "$domain" "$release" "$namespace" "$ingress_class" "$tls_secret")" || { rm -f "${rendered_files[@]}"; return 1; }
        rendered_files+=("$layer"); value_files+=(-f "$layer")
    fi
    if [ "$pages_enabled" = "true" ]; then
        local pages_namespace_in_path="true" pages_tls_secret="$tls_secret"
        if [ "$pages_subdomain_wildcard" = "true" ]; then
            pages_namespace_in_path="false"
            pages_tls_secret="$pages_wildcard_tls_secret"
        fi
        layer="$(_saas_gitlab_render_values_layer "$_SAAS_GITLAB_DIR/values/pages.yaml.tpl" "$domain" "$release" "$namespace" "$ingress_class" "$pages_tls_secret" "$pages_namespace_in_path")" || { rm -f "${rendered_files[@]}"; return 1; }
        rendered_files+=("$layer"); value_files+=(-f "$layer")
    fi

    helm upgrade --install "$release" gitlab/gitlab \
        --namespace "$namespace" --create-namespace \
        --version "$version" "${value_files[@]}" \
        --timeout 20m --wait
    local helm_status=$?
    rm -f "${rendered_files[@]}"
    [ "$helm_status" -eq 0 ] || { _saas_log_err "The GitLab chart install failed."; return 1; }

    if [ "$runner_enabled" = "true" ]; then
        _saas_log_step "Deploying and registering GitLab Runner…"
        _saas_gitlab_runner_install "$namespace" "$release" "$domain" || \
            _saas_log_warn "GitLab Runner could not be deployed/registered. Retry with 'saas gitlab runner reregister $release'."
    fi

    local ssh_note=""
    if [ "$cluster_mode" = "kind" ]; then
        _saas_log_step "Exposing GitLab SSH on host port ${ssh_host_port}…"
        _saas_gitlab_ssh_expose "$kind_name" "$namespace" "$release" "$ssh_host_port" || \
            _saas_log_warn "Could not expose GitLab SSH. Retry with 'saas gitlab ssh-config $release'."
    fi

    _saas_gitlab_state_save "$release" \
        "RELEASE=$release" "NAMESPACE=$namespace" "CLUSTER_MODE=$cluster_mode" \
        "KIND_NAME=$kind_name" "KIND_WORKERS=$kind_workers" "STORAGE_MODE=$storage_mode" "STORAGE_CLASS=$storage_class" \
        "MODE=$mode" "VERSION=$version" "DOMAIN=$domain" "TLS=$tls" "ISSUER_NAME=$issuer_name" \
        "CHALLENGE=$challenge" "DNS_PROVIDER=$dns_provider" "EMAIL=$email" \
        "INGRESS_CLASS=$ingress_class" "SSH_HOST_PORT=$ssh_host_port" "RUNNER_ENABLED=$runner_enabled" \
        "REGISTRY_ENABLED=$registry_enabled" "PAGES_ENABLED=$pages_enabled" "PAGES_URL_MODE=$pages_url_mode" \
        "PSQL_PASSWORD=$psql_password" "MINIO_ROOT_USER=$minio_user" "MINIO_ROOT_PASSWORD=$minio_password" \
        "ROOT_PASSWORD=$root_password" "REDIS_PASSWORD=$redis_password" \
        "STATUS=up"

    _saas_log_ok "GitLab '$release' is ready."
    _saas_gitlab_credentials "$release"
}

_saas_gitlab_up_help() {
    cat <<'EOF'
Usage: saas gitlab up [RELEASE] [OPTIONS]

Recreates RELEASE's kind cluster (previously destroyed with 'saas gitlab
down', without --purge-storage) and reinstalls GitLab reusing the state
saved from the original install: same credentials, same domain, same
data. Only applies to installs with --cluster-mode kind.

Cost: several minutes of startup time (recreating the cluster and
reinstalling the chart), not an instant resume. See 'saas gitlab down
--help'.

Options:
  -y, --yes       Don't ask for anything extra
  -h, --help      Show this help

Examples:
  saas gitlab up
  saas gitlab up demo
EOF
}

_saas_gitlab_up() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_gitlab_up -- "$@") || { _saas_gitlab_up_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_gitlab_up_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for release '$release'. Use 'saas gitlab install' first."; return 1; }
    [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'up' only applies to installs with --cluster-mode kind."; return 1; }

    _saas_gitlab_provision "$SAAS_GITLAB_STATE_RELEASE" "$SAAS_GITLAB_STATE_NAMESPACE" "$SAAS_GITLAB_STATE_CLUSTER_MODE" \
        "$SAAS_GITLAB_STATE_KIND_NAME" "$SAAS_GITLAB_STATE_KIND_WORKERS" "$SAAS_GITLAB_STATE_STORAGE_MODE" "" \
        "$SAAS_GITLAB_STATE_MODE" "$SAAS_GITLAB_STATE_VERSION" "$SAAS_GITLAB_STATE_DOMAIN" "$SAAS_GITLAB_STATE_TLS" \
        "$SAAS_GITLAB_STATE_ISSUER_NAME" "$SAAS_GITLAB_STATE_CHALLENGE" "$SAAS_GITLAB_STATE_DNS_PROVIDER" "" \
        "$SAAS_GITLAB_STATE_EMAIL" "$SAAS_GITLAB_STATE_INGRESS_CLASS" "$SAAS_GITLAB_STATE_SSH_HOST_PORT" \
        "$SAAS_GITLAB_STATE_RUNNER_ENABLED" "$SAAS_GITLAB_STATE_REGISTRY_ENABLED" "$SAAS_GITLAB_STATE_PAGES_ENABLED" \
        "${SAAS_GITLAB_STATE_PAGES_URL_MODE:-path}" \
        "$SAAS_GITLAB_STATE_PSQL_PASSWORD" "$SAAS_GITLAB_STATE_MINIO_ROOT_USER" \
        "$SAAS_GITLAB_STATE_MINIO_ROOT_PASSWORD" "$SAAS_GITLAB_STATE_ROOT_PASSWORD" "$SAAS_GITLAB_STATE_REDIS_PASSWORD"
}

_saas_gitlab_down_help() {
    cat <<'EOF'
Usage: saas gitlab down [RELEASE] [OPTIONS]

Destroys RELEASE's kind cluster (host CPU/RAM usage drops to zero) while
preserving the data (PostgreSQL/Redis/MinIO/Gitaly) in the host's storage
directory. 'saas gitlab up' recovers it when recreating the cluster.
Only applies to installs with --cluster-mode kind.

Options:
  -y, --yes       Don't ask for confirmation
  -h, --help      Show this help

Examples:
  saas gitlab down
  saas gitlab down demo -y
EOF
}

_saas_gitlab_down() {
    local release="" yes=false
    local args
    args=$(getopt -o yh -l yes,help --name saas_gitlab_down -- "$@") || { _saas_gitlab_down_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_gitlab_down_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ] || { _saas_log_err "'down' only applies to installs with --cluster-mode kind."; return 1; }

    echo "This will destroy the kind cluster '$SAAS_GITLAB_STATE_KIND_NAME' (data is preserved on the host)." >&2
    _saas_confirm "$yes" || return 1

    _saas_gitlab_cluster_delete "$SAAS_GITLAB_STATE_KIND_NAME" false || return 1
    _saas_gitlab_state_save "$release" \
        "RELEASE=$SAAS_GITLAB_STATE_RELEASE" "NAMESPACE=$SAAS_GITLAB_STATE_NAMESPACE" "CLUSTER_MODE=$SAAS_GITLAB_STATE_CLUSTER_MODE" \
        "KIND_NAME=$SAAS_GITLAB_STATE_KIND_NAME" "KIND_WORKERS=$SAAS_GITLAB_STATE_KIND_WORKERS" "STORAGE_MODE=$SAAS_GITLAB_STATE_STORAGE_MODE" "STORAGE_CLASS=$SAAS_GITLAB_STATE_STORAGE_CLASS" \
        "MODE=$SAAS_GITLAB_STATE_MODE" "VERSION=$SAAS_GITLAB_STATE_VERSION" "DOMAIN=$SAAS_GITLAB_STATE_DOMAIN" "TLS=$SAAS_GITLAB_STATE_TLS" "ISSUER_NAME=$SAAS_GITLAB_STATE_ISSUER_NAME" \
        "CHALLENGE=$SAAS_GITLAB_STATE_CHALLENGE" "DNS_PROVIDER=$SAAS_GITLAB_STATE_DNS_PROVIDER" "EMAIL=$SAAS_GITLAB_STATE_EMAIL" \
        "INGRESS_CLASS=$SAAS_GITLAB_STATE_INGRESS_CLASS" "SSH_HOST_PORT=$SAAS_GITLAB_STATE_SSH_HOST_PORT" "RUNNER_ENABLED=$SAAS_GITLAB_STATE_RUNNER_ENABLED" \
        "REGISTRY_ENABLED=$SAAS_GITLAB_STATE_REGISTRY_ENABLED" "PAGES_ENABLED=$SAAS_GITLAB_STATE_PAGES_ENABLED" \
        "PAGES_URL_MODE=${SAAS_GITLAB_STATE_PAGES_URL_MODE:-path}" \
        "PSQL_PASSWORD=$SAAS_GITLAB_STATE_PSQL_PASSWORD" "MINIO_ROOT_USER=$SAAS_GITLAB_STATE_MINIO_ROOT_USER" "MINIO_ROOT_PASSWORD=$SAAS_GITLAB_STATE_MINIO_ROOT_PASSWORD" \
        "ROOT_PASSWORD=$SAAS_GITLAB_STATE_ROOT_PASSWORD" "REDIS_PASSWORD=$SAAS_GITLAB_STATE_REDIS_PASSWORD" \
        "STATUS=down"
    _saas_log_ok "kind cluster '$SAAS_GITLAB_STATE_KIND_NAME' destroyed. Data preserved. Use 'saas gitlab up $release' to bring it back up."
}

_saas_gitlab_delete_help() {
    cat <<'EOF'
Usage: saas gitlab delete [RELEASE] [OPTIONS]

Full uninstall: removes GitLab, its namespace, and (in --cluster-mode
kind) the cluster itself. Also removes the saved state.

Options:
      --purge-storage   Also removes the data persisted on the host
                        (--cluster-mode kind only). Irreversible
  -y, --yes             Don't ask for confirmation
  -h, --help             Show this help

Examples:
  saas gitlab delete
  saas gitlab delete demo --purge-storage -y
EOF
}

_saas_gitlab_delete() {
    local release="" yes=false purge=false
    local args
    args=$(getopt -o yh -l purge-storage,yes,help --name saas_gitlab_delete -- "$@") || { _saas_gitlab_delete_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --purge-storage) purge=true; shift ;;
            -y|--yes) yes=true; shift ;;
            -h|--help) _saas_gitlab_delete_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "This will completely remove the GitLab install '$release'$($purge && echo ' (including the data, --purge-storage)')." >&2
    _saas_confirm "$yes" || return 1

    if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ]; then
        _saas_gitlab_cluster_delete "$SAAS_GITLAB_STATE_KIND_NAME" "$purge" || return 1
    else
        helm uninstall "$SAAS_GITLAB_STATE_RELEASE" --namespace "$SAAS_GITLAB_STATE_NAMESPACE" 2>/dev/null
        kubectl delete clusterissuer "$SAAS_GITLAB_STATE_ISSUER_NAME" --ignore-not-found >/dev/null 2>&1
        if [ "$SAAS_GITLAB_STATE_MODE" = "prod" ]; then
            _saas_gitlab_datastore_ha_delete "$SAAS_GITLAB_STATE_NAMESPACE" "$SAAS_GITLAB_STATE_RELEASE"
        else
            _saas_gitlab_datastore_delete "$SAAS_GITLAB_STATE_NAMESPACE" "$SAAS_GITLAB_STATE_RELEASE"
        fi
        $purge && kubectl delete namespace "$SAAS_GITLAB_STATE_NAMESPACE" --ignore-not-found >/dev/null 2>&1
    fi

    _saas_gitlab_state_delete "$release"
    _saas_log_ok "Install '$release' removed."
}

_saas_gitlab_status_help() {
    cat <<'EOF'
Usage: saas gitlab status [RELEASE] [OPTIONS]

Shows RELEASE's saved state and, if the cluster is reachable, the real
status of its pods.

Options:
  -h, --help   Show this help
EOF
}

_saas_gitlab_status() {
    local release=""
    case "${1:-}" in -h|--help) _saas_gitlab_status_help; return 0 ;; esac
    release="${1:-$(_saas_gitlab_suggest_release)}"

    _saas_gitlab_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }

    echo "Release:        $SAAS_GITLAB_STATE_RELEASE"
    echo "Namespace:      $SAAS_GITLAB_STATE_NAMESPACE"
    echo "Cluster:        $SAAS_GITLAB_STATE_CLUSTER_MODE${SAAS_GITLAB_STATE_KIND_NAME:+ ($SAAS_GITLAB_STATE_KIND_NAME)}"
    echo "Mode:           $SAAS_GITLAB_STATE_MODE"
    echo "Chart version:  $SAAS_GITLAB_STATE_VERSION"
    echo "Domain:         $SAAS_GITLAB_STATE_DOMAIN"
    echo "TLS:            $SAAS_GITLAB_STATE_TLS"
    echo "Runner:         $SAAS_GITLAB_STATE_RUNNER_ENABLED"
    echo "Registry:       $SAAS_GITLAB_STATE_REGISTRY_ENABLED"
    echo "Pages:          $SAAS_GITLAB_STATE_PAGES_ENABLED"
    echo "Pages URL mode: ${SAAS_GITLAB_STATE_PAGES_URL_MODE:-path}"
    echo "Saved status:   $SAAS_GITLAB_STATE_STATUS"

    if [ "$SAAS_GITLAB_STATE_CLUSTER_MODE" = "kind" ] && ! _saas_gitlab_cluster_exists "$SAAS_GITLAB_STATE_KIND_NAME" 2>/dev/null; then
        echo
        echo "The kind cluster doesn't currently exist (a 'saas gitlab down' pending 'up'?)."
        return 0
    fi

    if kubectl -n "$SAAS_GITLAB_STATE_NAMESPACE" get pods >/dev/null 2>&1; then
        echo
        kubectl -n "$SAAS_GITLAB_STATE_NAMESPACE" get pods
    fi
}
