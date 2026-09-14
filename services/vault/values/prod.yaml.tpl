# 'prod' overlay for the openbao/openbao chart: 3-replica HA Raft (integrated storage), each node
# joining the other two over mTLS on 8201 via retry_join. Same note as dev.yaml.tpl about
# server.volumes/extraContainers living in unseal.yaml.tpl instead of here (Helm's '-f' layers
# don't deep-merge lists). Variables substituted by envsubst.
#
# 'server.affinity' softens the chart's own default (a REQUIRED pod anti-affinity by hostname:
# verified live it leaves replicas 1/2 permanently stuck Pending - "didn't match pod anti-affinity
# rules", never a timing issue - on this tool's own default single-node kind cluster, since there's
# only ever one schedulable node to place them on). Kept as a PREFERRED anti-affinity instead, same
# labelSelector/topologyKey the chart itself uses by default: a real multi-node cluster (more kind
# workers, or --cluster-mode existing against one) still gets genuine per-host spreading, while the
# tool's own default topology no longer deadlocks. See CLAUDE.md.
global:
  tlsDisable: false
injector:
  enabled: false
server:
  affinity: |
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: openbao
                app.kubernetes.io/instance: "${SAAS_RELEASE}"
                component: server
            topologyKey: kubernetes.io/hostname
  ha:
    enabled: true
    replicas: 3
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
          retry_join {
            leader_api_addr = "https://${SAAS_FULLNAME}-0.${SAAS_FULLNAME}-internal:8200"
            leader_ca_cert_file = "/openbao/tls/ca.crt"
          }
          retry_join {
            leader_api_addr = "https://${SAAS_FULLNAME}-1.${SAAS_FULLNAME}-internal:8200"
            leader_ca_cert_file = "/openbao/tls/ca.crt"
          }
          retry_join {
            leader_api_addr = "https://${SAAS_FULLNAME}-2.${SAAS_FULLNAME}-internal:8200"
            leader_ca_cert_file = "/openbao/tls/ca.crt"
          }
        }
        telemetry {
          disable_hostname = true
        }
        service_registration "kubernetes" {}
    disruptionBudget:
      maxUnavailable: 1
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: ${SAAS_STORAGE_CLASS}
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits: {cpu: 1000m, memory: 1Gi}
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
