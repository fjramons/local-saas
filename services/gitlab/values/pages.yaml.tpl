# Optional overlay layered on top of dev.yaml.tpl/prod.yaml.tpl when --pages is on (off by default).
# Reuses the same object-store connection Secret as the rest of GitLab (the 'gitlab-pages' bucket is
# already pre-created by datastore.sh's bucket list). The chart doesn't force a dedicated secret.
#
# namespaceInPath: true trades subdomain-style Pages URLs (project.group.pages.<domain>, which needs
# a WILDCARD *.pages.<domain> certificate, obtainable only via DNS-01) for path-style ones under a
# single non-wildcard host (pages.<domain>/group/project/). This keeps Pages working with
# self-signed and HTTP-01 TLS too, instead of forcing --challenge dns01 whenever --pages is on.
# Variables substituted by envsubst, see services/gitlab/lib/install.sh.
global:
  pages:
    enabled: true
    host: pages.${SAAS_DOMAIN}
    namespaceInPath: true
    objectStore:
      enabled: true
      bucket: gitlab-pages
      connection:
        secret: ${SAAS_RELEASE}-datastore-objectstore
        key: connection
  hosts:
    pages:
      name: pages.${SAAS_DOMAIN}
