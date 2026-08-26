# Optional overlay layered on top of dev.yaml.tpl/prod.yaml.tpl when --pages is on (off by default).
# Reuses the same object-store connection Secret as the rest of GitLab (the 'gitlab-pages' bucket is
# already pre-created by datastore.sh's bucket list). The chart doesn't force a dedicated secret.
#
# namespaceInPath is controlled by --pages-url-mode (install.sh). 'path' (default) trades
# subdomain-style Pages URLs (<namespace>.pages.<domain>/<project>, which needs a WILDCARD
# *.pages.<domain> certificate, only obtainable via DNS-01 with a real CA) for path-style ones under
# a single non-wildcard host (pages.<domain>/<group>/<project>/), keeping Pages working with
# self-signed and HTTP-01 TLS too, instead of forcing a wildcard whenever --pages is on. 'subdomain'
# opts into the chart's native per-namespace routing instead, requiring --tls self-signed (which can
# sign a wildcard SAN locally, no CA validation involved) or --tls letsencrypt --challenge dns01.
#
# The chart's own Pages Ingress TLS secret lookup (charts/gitlab/charts/gitlab-pages/templates/
# _helpers.tpl, "pages.tlsSecret") checks gitlab.gitlab-pages.ingress.tls.secretName first, falling
# back to the shared global.ingress.tls.secretName if unset. In 'path' mode this is set to the same
# secret the rest of GitLab already uses (equivalent to relying on that fallback, just explicit); in
# 'subdomain' mode it's set to the standalone wildcard Certificate's Secret that install.sh issues
# only in that mode (see tls.sh's _saas_gitlab_certificate_request, called a second time with a
# wildcard DOMAIN), so the main certificate never needs to become a wildcard itself.
#
# Variables substituted by envsubst, see services/gitlab/lib/install.sh.
global:
  pages:
    enabled: true
    host: pages.${SAAS_DOMAIN}
    namespaceInPath: ${SAAS_PAGES_NAMESPACE_IN_PATH}
    objectStore:
      enabled: true
      bucket: gitlab-pages
      connection:
        secret: ${SAAS_RELEASE}-datastore-objectstore
        key: connection
  hosts:
    pages:
      name: pages.${SAAS_DOMAIN}
gitlab:
  gitlab-pages:
    ingress:
      tls:
        secretName: ${SAAS_TLS_SECRET}
