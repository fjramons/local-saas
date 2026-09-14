# --- cert-manager + TLS for 'saas vault'. Two independent PKI concerns:
#
# 1) EXTERNAL cert: the one ingress-nginx presents to the outside world for Vault's UI/API
#    domain, same flag surface as gitlab's (--tls self-signed|letsencrypt, --challenge http01|
#    dns01), re-encrypted to Vault's own internal-CA backend rather than passed through.
#    Deliberately narrower than gitlab's: --dns-provider only supports 'cloudflare' (native to
#    cert-manager), not 'duckdns'. gitlab's CLAUDE.md calls the DuckDNS third-party webhook "the
#    ONE deliberate exception... any future provider needing a webhook requires an equally
#    explicit decision, not a precedent from this one" - so it is deliberately NOT extended here;
#    revisit only with an equally explicit decision, exactly as that note anticipates.
#
# 2) INTERNAL PKI bootstrap chain for Vault's own Raft/API TLS listener (mandatory, not
#    controlled by --tls at all): a self-signed root -> internal CA -> leaf certificate chain,
#    adapted from a real production OpenBao deployment's cert-manager setup (portable, no vendor
#    lock-in there), fully independent of whichever external TLS mode was chosen.

_saas_vault_valid_tls_mode()     { [[ "$1" == "self-signed" || "$1" == "letsencrypt" ]]; }
_saas_vault_valid_challenge()    { [[ "$1" == "http01" || "$1" == "dns01" ]]; }
_saas_vault_valid_dns_provider() { [[ "$1" == "cloudflare" ]]; }

# --- 1) External cert issuers (same shape as services/gitlab/lib/tls.sh's, minus DuckDNS) ---

_saas_vault_certmanager_issuer_selfsigned() {
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

# _saas_vault_certmanager_issuer_letsencrypt_http01 NAME EMAIL INGRESS_CLASS [SERVER]
_saas_vault_certmanager_issuer_letsencrypt_http01() {
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

# _saas_vault_certmanager_issuer_letsencrypt_dns01_cloudflare NAME EMAIL TOKEN [SERVER]
# TOKEN: a Cloudflare API Token with Zone:DNS:Edit permission for the domain's zone (not the Global API Key).
_saas_vault_certmanager_issuer_letsencrypt_dns01_cloudflare() {
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

# _saas_vault_certificate_request NAMESPACE NAME DOMAIN ISSUER SECRET_NAME
# External UI/API certificate. See services/gitlab/lib/tls.sh for why every dnsName is quoted.
_saas_vault_certificate_request() {
    local ns="$1" name="$2" domain="$3" issuer="$4" secret_name="$5"

    kubectl -n "$ns" apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${name}
spec:
  secretName: ${secret_name}
  dnsNames: ["${domain}"]
  issuerRef: {name: ${issuer}, kind: ClusterIssuer}
EOF

    _saas_log_wait "Waiting for the external TLS certificate for ${domain} (issuer: ${issuer})…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=180s "certificate/${name}"
}

# --- 2) Internal PKI bootstrap chain for Vault's own Raft/API listener ---
#
# Adapted from a real production OpenBao deployment's cert-manager setup: a self-signed root
# issuer signs a 3-year internal CA certificate, which becomes a second ClusterIssuer used to sign
# the actual leaf certificate OpenBao mounts for its listener (90-day, auto-rotated by
# cert-manager, picked up via Reloader's pod-restart annotation, see values/unseal.yaml.tpl).
# Every name is namespaced by RELEASE so more than one vault release can coexist in the same
# cluster (--cluster-mode existing) without colliding on a cluster-scoped ClusterIssuer name.

# _saas_vault_fullname RELEASE
# Mirrors the openbao/openbao CHART's own '<chart>.fullname' Helm helper (the standard "if the
# release name already contains the chart name, use it as-is, else '<release>-<chart>'"
# convention) - deliberately still checks for the literal substring "openbao", NEVER "vault":
# that's the upstream chart's own name (its Chart.yaml, not ours to rename), so with this
# project's own default release name "vault" (which doesn't contain "openbao"), this now almost
# always resolves to "<release>-openbao" (e.g. "vault-openbao"), matching real generated pod/
# Service names, not "<release>-<release>". Only a release explicitly named to contain "openbao"
# (or the chart's own bare default) collapses instead, exactly like Helm's own logic would.
_saas_vault_fullname() {
    local release="$1"
    case "$release" in
        *openbao*) echo "$release" ;;
        *) echo "${release}-openbao" ;;
    esac
}

# _saas_vault_internal_pki_bootstrap NAMESPACE RELEASE
# Idempotent (kubectl apply); safe to call on every install/up.
_saas_vault_internal_pki_bootstrap() {
    local ns="$1" release="$2"
    local fullname selfsigned_issuer ca_cert_name ca_issuer leaf_cert_name leaf_secret_name
    fullname="$(_saas_vault_fullname "$release")"
    selfsigned_issuer="${release}-vault-selfsigned-issuer"
    ca_cert_name="${release}-vault-internal-ca"
    ca_issuer="${release}-vault-internal-ca-issuer"
    leaf_cert_name="${release}-vault-int-cert"
    leaf_secret_name="${release}-vault-int-tls"

    kubectl apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${selfsigned_issuer}
spec:
  selfSigned: {}
EOF

    kubectl -n cert-manager apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${ca_cert_name}
spec:
  isCA: true
  commonName: ${release}-vault-internal-ca
  secretName: ${ca_cert_name}
  duration: 26280h
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: ${selfsigned_issuer}, kind: ClusterIssuer}
EOF
    _saas_log_wait "Waiting for the internal CA certificate…"
    kubectl -n cert-manager wait --for=condition=Ready --timeout=180s "certificate/${ca_cert_name}" || return 1

    kubectl apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ca_issuer}
spec:
  ca:
    secretName: ${ca_cert_name}
EOF

    kubectl -n "$ns" apply -f - <<EOF || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${leaf_cert_name}
spec:
  secretName: ${leaf_secret_name}
  duration: 2160h
  renewBefore: 720h
  privateKey:
    rotationPolicy: Always
  dnsNames:
    - "${fullname}-active"
    - "*.${fullname}-internal"
    - "*.${fullname}-internal.${ns}"
    - "*.${fullname}-internal.${ns}.svc"
    - "*.${fullname}-internal.${ns}.svc.cluster.local"
  ipAddresses: ["127.0.0.1"]
  issuerRef: {name: ${ca_issuer}, kind: ClusterIssuer}
EOF
    _saas_log_wait "Waiting for Vault's internal listener certificate…"
    kubectl -n "$ns" wait --for=condition=Ready --timeout=180s "certificate/${leaf_cert_name}"
}
