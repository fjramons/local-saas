# Overlay layered on top of prod.yaml.tpl whenever --mode prod (always, HA is unconditional in prod,
# see install.sh), pointing the chart at the HA datastore provisioned by datastore-ha.sh
# instead of the single-instance one in dev.yaml.tpl/datastore.sh.
#
# global.redis.host is NOT a hostname here. The Sentinel-aware Redis client baked into Omnibus
# GitLab expects the Sentinel MASTER GROUP NAME when Sentinels are configured. redis-operator's own
# default is "myMaster" (mixed case) if left unset, verified live that it is in fact a real,
# settable field (RedisSentinel.spec.redisSentinelConfig.masterGroupName), NOT hardcoded as earlier
# assumed. datastore-ha.sh sets it explicitly to "mymaster" (lowercase, the far more common
# convention) so this value matches it exactly. A case mismatch here means Sentinel returns "ERR No
# such master with that name" to every client, reproduced live before this was fixed.
# sentinelAuth.enabled: false is the deliberate trade-off
# documented in datastore-ha.sh (Sentinel port left unauthenticated, pending an upstream
# fix; the actual Redis data connection stays fully password-protected via 'auth'). Variables
# substituted by envsubst, see services/gitlab/lib/install.sh.
global:
  psql:
    host: ${SAAS_RELEASE}-postgresql-rw.${SAAS_NAMESPACE}.svc.cluster.local
    username: gitlab
    password:
      secret: ${SAAS_RELEASE}-datastore-psql
      key: password
  redis:
    host: mymaster
    auth:
      enabled: true
      secret: ${SAAS_RELEASE}-datastore-redis
      key: password
    sentinels:
      - host: ${SAAS_RELEASE}-redis-sentinel.${SAAS_NAMESPACE}.svc.cluster.local
        port: 26379
    sentinelAuth:
      enabled: false
