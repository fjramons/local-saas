# 'dev' overlay for the openbao/openbao chart: single-node integrated storage (Raft is still the
# real storage backend, just with one voter, no retry_join needed). Reduced resources. Ingress
# re-encrypts to Vault's own internal-CA-issued listener certificate (server.volumes/volumeMounts
# for /openbao/tls, plus the unseal-sidecar, live in unseal.yaml.tpl instead of here: Helm doesn't
# deep-merge list values across '-f' layers, so any layer that also touched server.volumes /
# server.extraContainers would silently replace this file's lists instead of adding to them - see
# services/vault/lib/install.sh). Variables substituted by envsubst.
global:
  tlsDisable: false
injector:
  enabled: false
server:
  ha:
    enabled: true
    replicas: 1
    raft:
      enabled: true
      config: |
        ui = true
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/openbao/tls/tls.crt"
          tls_key_file = "/openbao/tls/tls.key"
          tls_client_ca_file = "/openbao/tls/ca.crt"
        }
        storage "raft" {
          path = "/openbao/data"
        }
        telemetry {
          disable_hostname = true
        }
        service_registration "kubernetes" {}
    disruptionBudget:
      maxUnavailable: 0
  dataStorage:
    enabled: true
    size: 2Gi
    storageClass: ${SAAS_STORAGE_CLASS}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: 500m, memory: 512Mi}
  annotations:
    secret.reloader.stakater.com/reload: ${SAAS_RELEASE}-vault-int-tls
  ingress:
    enabled: true
    ingressClassName: ${SAAS_INGRESS_CLASS}
    annotations:
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
      nginx.ingress.kubernetes.io/proxy-ssl-verify: "false"
    hosts:
      - host: ${SAAS_DOMAIN}
        paths: []
    tls:
      - secretName: ${SAAS_TLS_SECRET}
        hosts: ["${SAAS_DOMAIN}"]
