# 'prod' overlay for the gitlab/gitlab chart: resources aligned to the chart's official baseline (~8 vCPU/16GB), 2 replicas on the horizontally-scalable components. PostgreSQL/Redis/MinIO now run with real HA (CloudNativePG, Redis Sentinel via redis-operator, 4-node distributed MinIO); global.psql/global.redis are supplied by values/datastore-ha.yaml.tpl, always layered on top of this file in --mode prod (see install.sh), not duplicated here. Container Registry defaults here to off (base 'registry.enabled: false') and is layered on by values/registry.yaml.tpl when --registry is enabled (on by default), same for Pages via values/pages.yaml.tpl. Variables substituted by envsubst, see services/gitlab/lib/install.sh.
global:
  edition: ce
  hosts:
    domain: ${SAAS_DOMAIN}
    https: true
    gitlab:
      name: ${SAAS_DOMAIN}
  ingress:
    enabled: true
    provider: nginx
    class: ${SAAS_INGRESS_CLASS}
    configureCertmanager: false
    tls:
      enabled: true
      secretName: ${SAAS_TLS_SECRET}
  initialRootPassword:
    secret: ${SAAS_RELEASE}-gitlab-initial-root-password
    key: password
  appConfig:
    object_store:
      enabled: true
      connection:
        secret: ${SAAS_RELEASE}-datastore-objectstore
        key: connection
  gatewayApi:
    enabled: false
    installEnvoy: false
    configureCertmanager: false
  kas:
    enabled: false

installCertmanager: false

nginx-ingress:
  enabled: false

gitlab-runner:
  install: false

registry:
  enabled: false

prometheus:
  install: false

gitlab-zoekt:
  install: false

gitlab:
  webservice:
    minReplicas: 2
    maxReplicas: 2
    resources:
      requests: {cpu: "1", memory: 2500Mi}
  sidekiq:
    minReplicas: 1
    maxReplicas: 2
    resources:
      requests: {cpu: 300m, memory: 1200Mi}
  gitaly:
    resources:
      requests: {cpu: 500m, memory: 1500Mi}
    persistence:
      size: 50Gi
  gitlab-shell:
    resources:
      requests: {cpu: 100m, memory: 128Mi}
  toolbox:
    resources:
      requests: {cpu: 100m, memory: 512Mi}
    backups:
      objectStorage:
        backend: s3
        config:
          secret: ${SAAS_RELEASE}-datastore-s3cfg
          key: config
  migrations:
    resources:
      requests: {cpu: 200m, memory: 512Mi}
