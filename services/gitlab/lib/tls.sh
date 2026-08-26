# --- cert-manager + TLS certificate issuance for 'saas gitlab'.
#
# --tls self-signed: 'selfSigned' ClusterIssuer — zero external dependencies, ideal for --mode dev / local kind without exposing it to the internet.
# --tls letsencrypt --challenge http01: needs the ingress to be reachable from the internet on port 80 (that's how Let's Encrypt validates domain ownership).
# --tls letsencrypt --challenge dns01 --dns-provider cloudflare: doesn't need public reachability — proves domain ownership by creating a TXT record via the DNS provider's API. The only provider with native support implemented in this first version (cert-manager supports it without a third-party webhook). Requires the domain to be delegated to Cloudflare.
#
# 'duckdns' is documented as a free "no domain of your own needed" option for DNS-01 (see README/CLAUDE.md) but is NOT implemented yet: it needs a third-party cert-manager webhook that couldn't be verified from this environment without compromising the reliability of the delivered code — see CLAUDE.md, "Design notes", for the extension point.

_saas_gitlab_valid_tls_mode()       { [[ "$1" == "self-signed" || "$1" == "letsencrypt" ]]; }
_saas_gitlab_valid_challenge()      { [[ "$1" == "http01" || "$1" == "dns01" ]]; }
_saas_gitlab_valid_dns_provider()   { [[ "$1" == "cloudflare" || "$1" == "duckdns" ]]; }

_SAAS_GITLAB_CERTMANAGER_VERSION_HINT="see 'helm search repo jetstack/cert-manager --versions' (always latest stable, not pinned)"

# _saas_gitlab_certmanager_ensure
# Idempotent: does nothing if cert-manager is already installed (CRDs present).
_saas_gitlab_certmanager_ensure() {
    if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        _saas_log_info "cert-manager is already installed."
        return 0
    fi

    _saas_log_step "Installing cert-manager…"
    if ! helm repo list -o json 2>/dev/null | jq -e '.[]? | select(.name == "jetstack")' >/dev/null; then
        helm repo add jetstack https://charts.jetstack.io >/dev/null || return 1
    fi
    helm repo update jetstack >/dev/null || return 1

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true --wait --timeout 180s
}

# _saas_gitlab_certmanager_issuer_selfsigned NAME
_saas_gitlab_certmanager_issuer_selfsigned() {
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

# _saas_gitlab_certmanager_issuer_letsencrypt_http01 NAME EMAIL INGRESS_CLASS [SERVER]
_saas_gitlab_certmanager_issuer_letsencrypt_http01() {
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

# _saas_gitlab_certmanager_issuer_letsencrypt_dns01_cloudflare NAME EMAIL TOKEN [SERVER]
# TOKEN: a Cloudflare API Token with Zone:DNS:Edit permission for the domain's zone (not the Global API Key).
_saas_gitlab_certmanager_issuer_letsencrypt_dns01_cloudflare() {
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

# _saas_gitlab_certificate_request NAMESPACE NAME DOMAIN ISSUER SECRET_NAME
# Creates/updates a Certificate and waits (up to 180s) for it to become Ready.
_saas_gitlab_certificate_request() {
    local ns="$1" name="$2" domain="$3" issuer="$4" secret_name="$5"

    kubectl -n "$ns" apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${name}
spec:
  secretName: ${secret_name}
  dnsNames: [${domain}]
  issuerRef: {name: ${issuer}, kind: ClusterIssuer}
EOF

    _saas_log_wait "Waiting for the TLS certificate for ${domain} (issuer: ${issuer})…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=180s "certificate/${name}"
}
