# --- cert-manager + TLS certificate issuance for 'saas postgres'. Same scope as
# services/minio/lib/tls.sh (self-signed / letsencrypt http01 / letsencrypt dns01 cloudflare only):
# no DuckDNS webhook here, same reasoning as vault's/minio's own choice not to extend gitlab's one
# deliberate webhook exception to another service without an equally explicit decision.
#
# Unlike MinIO/GitLab/Vault, the issued certificate is never served through an Ingress: PostgreSQL
# speaks its own wire protocol, not HTTP, so the Certificate's Secret is instead mounted directly
# into the PostgreSQL workload itself (see backend.sh) for the server's own 'ssl_cert_file'/
# 'ssl_key_file'. DOMAIN here is only ever the certificate's CN/SAN identity (matters for a host
# psql client using sslmode=verify-full against a --tls letsencrypt certificate); self-signed mode
# gives encryption without hostname/CA verification (sslmode=require), the same trust level this
# repo's other "self-signed" TLS modes already provide, deliberately, not an oversight.

_saas_postgres_valid_tls_mode()     { [[ "$1" == "self-signed" || "$1" == "letsencrypt" ]]; }
_saas_postgres_valid_challenge()    { [[ "$1" == "http01" || "$1" == "dns01" ]]; }
_saas_postgres_valid_dns_provider() { [[ "$1" == "cloudflare" ]]; }

# cert-manager's own idempotent install lives in lib/common.sh as _saas_ensure_certmanager, shared
# with gitlab/vault/minio. Everything below (issuers, certificate requests) stays here: it genuinely
# differs per service (domains, which challenge types are offered).

# _saas_postgres_certmanager_issuer_selfsigned NAME
_saas_postgres_certmanager_issuer_selfsigned() {
    local name="$1"
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  selfSigned: {}
EOF
}

# _saas_postgres_certmanager_issuer_letsencrypt_http01 NAME EMAIL INGRESS_CLASS [SERVER]
# The HTTP-01 solver still needs an Ingress controller to answer the ACME challenge, even though
# the issued certificate itself is never served through an Ingress afterward (see the file header).
_saas_postgres_certmanager_issuer_letsencrypt_http01() {
    local name="$1" email="$2" ingress_class="$3" server="${4:-https://acme-v02.api.letsencrypt.org/directory}"
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    server: ${server}
    email: ${email}
    privateKeySecretRef: {name: ${name}-account-key}
    solvers:
      - http01:
          ingress: {ingressClassName: ${ingress_class}}
EOF
}

# _saas_postgres_certmanager_issuer_letsencrypt_dns01_cloudflare NAME EMAIL TOKEN [SERVER]
# TOKEN: a Cloudflare API Token with Zone:DNS:Edit permission for the domain's zone (not the Global API Key).
_saas_postgres_certmanager_issuer_letsencrypt_dns01_cloudflare() {
    local name="$1" email="$2" token="$3" server="${4:-https://acme-v02.api.letsencrypt.org/directory}"

    kubectl -n cert-manager create secret generic "${name}-cloudflare-token" \
        --from-literal=api-token="$token" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    server: ${server}
    email: ${email}
    privateKeySecretRef: {name: ${name}-account-key}
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef: {name: ${name}-cloudflare-token, key: api-token, namespace: cert-manager}
EOF
}

# _saas_postgres_certificate_request NAMESPACE NAME DOMAIN ISSUER SECRET_NAME [EXTRA_SAN...]
# Creates/updates a Certificate and waits (up to 180s) for it to become Ready. Same quoting of every
# dnsName as every other service's own certificate_request (a leading '*' would otherwise be YAML's
# alias indicator; harmless no-op for a plain hostname). The Secret this produces
# (SECRET_NAME, type kubernetes.io/tls, keys tls.crt/tls.key/ca.crt) is mounted directly into the
# PostgreSQL workload by backend.sh, never referenced by an Ingress.
_saas_postgres_certificate_request() {
    local ns="$1" name="$2" domain="$3" issuer="$4" secret_name="$5"
    shift 5
    local -a dns_names=("$domain" "$@")

    local dns_names_yaml="" d
    for d in "${dns_names[@]}"; do
        dns_names_yaml+="\"${d}\","
    done
    dns_names_yaml="${dns_names_yaml%,}"

    kubectl -n "$ns" apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${name}
spec:
  secretName: ${secret_name}
  dnsNames: [${dns_names_yaml}]
  issuerRef: {name: ${issuer}, kind: ClusterIssuer}
EOF

    _saas_log_wait "Waiting for the TLS certificate for ${domain} (issuer: ${issuer})…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=180s "certificate/${name}"
}
