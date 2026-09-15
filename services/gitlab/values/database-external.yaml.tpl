# Layered on top of the base mode overlay (and, in --mode prod, on top of datastore-ha.yaml.tpl too)
# only when --database external is used: points the chart at a shared PostgreSQL instance managed
# by 'saas postgres' instead of GitLab's own private one. Confirmed live against the real chart
# ('helm show values gitlab/gitlab'): global.psql has no sslMode/ssl override key at all (the ones
# found in the schema belong to Praefect's own separate DB config and an unrelated secrets-manager
# storage block, not the main Rails app connection), so none is set here. Also confirmed live:
# a plain client connection with NO sslmode specified at all still negotiates TLS successfully
# against this service's own always-TLS-enforcing PostgreSQL (libpq's own default sslmode, "prefer",
# already does this), so the missing override key is not a gap, just unnecessary here.
global:
  psql:
    host: ${SAAS_PSQL_HOST}
    port: ${SAAS_PSQL_PORT}
