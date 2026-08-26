# 'prod' overlay for the gitlab/gitlab chart: resources aligned to the chart's official baseline (~8 vCPU/16GB), 2 replicas on the horizontally-scalable components, external PostgreSQL/Redis/MinIO pointing at the stack deployed by services/gitlab/lib/datastore.sh (single instance — no HA; see CLAUDE.md, known limitation). Container Registry stays disabled in this mode too in this first version — see CLAUDE.md, "Design notes", for why and how to enable it by hand. Variables substituted by envsubst — see services/gitlab/lib/install.sh.
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
