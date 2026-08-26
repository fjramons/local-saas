# Optional overlay layered on top of dev.yaml.tpl/prod.yaml.tpl when --registry is on (default).
# The registry subchart does NOT reuse global.appConfig.object_store (verified against the chart's
# own values.yaml). It needs its own 'registry.storage.secret', pointing at the S3-config Secret
# datastore.sh always creates (${SAAS_RELEASE}-datastore-registry-storage). Variables substituted by
# envsubst, see services/gitlab/lib/install.sh.
registry:
  enabled: true
  storage:
    secret: ${SAAS_RELEASE}-datastore-registry-storage
    key: config

global:
  registry:
    enabled: true
    bucket: registry
  hosts:
    registry:
      name: registry.${SAAS_DOMAIN}
