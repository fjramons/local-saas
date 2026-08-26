# 'dev' overlay for the gitlab/gitlab chart: reduced resources, a single replica per component, Container Registry/Pages/KAS/Prometheus/Grafana disabled, external PostgreSQL/Redis/MinIO pointing at the minimal stack deployed by services/gitlab/lib/datastore.sh. Variables substituted by envsubst — see services/gitlab/lib/install.sh.
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
  psql:
    host: ${SAAS_RELEASE}-postgresql.${SAAS_NAMESPACE}.svc.cluster.local
    username: gitlab
    password:
      secret: ${SAAS_RELEASE}-datastore-psql
      key: password
  redis:
    host: ${SAAS_RELEASE}-redis.${SAAS_NAMESPACE}.svc.cluster.local
    auth:
      enabled: false
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
    minReplicas: 1
    maxReplicas: 1
    resources:
      requests: {cpu: 300m, memory: 1400Mi}
  sidekiq:
    minReplicas: 1
    maxReplicas: 1
    resources:
      requests: {cpu: 100m, memory: 700Mi}
  gitaly:
    resources:
      requests: {cpu: 100m, memory: 512Mi}
    persistence:
      size: 5Gi
  gitlab-shell:
    resources:
      requests: {cpu: 50m, memory: 64Mi}
  toolbox:
    resources:
      requests: {cpu: 50m, memory: 256Mi}
    backups:
      objectStorage:
        backend: s3
        config:
          secret: ${SAAS_RELEASE}-datastore-s3cfg
          key: config
  migrations:
    resources:
      requests: {cpu: 100m, memory: 256Mi}
