# Applied into the POSTGRES cluster, via 'saas postgres integrate vault', once Vault's own side of
# the integration (KV engine, Kubernetes auth trust, policy/role) is confirmed ready. Same shape as
# minio-secretstore.yaml.tpl: a ClusterSecretStore (not namespaced, for the same admission-webhook
# reason documented there), named per-postgres-release since ClusterSecretStore names are
# cluster-wide. Variables substituted by envsubst.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-ca
  namespace: ${SAAS_POSTGRES_NAMESPACE}
data:
  ca.crt: ${SAAS_VAULT_CA_BUNDLE_B64}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_POSTGRES_RELEASE}
spec:
  provider:
    vault:
      server: ${SAAS_VAULT_URL}
      path: postgres/${SAAS_POSTGRES_RELEASE}
      version: v2
      caProvider:
        type: Secret
        name: ${SAAS_VAULT_RELEASE}-vault-ca
        namespace: ${SAAS_POSTGRES_NAMESPACE}
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${SAAS_VAULT_RELEASE}-postgres-${SAAS_POSTGRES_RELEASE}-role
          serviceAccountRef:
            name: ${SAAS_ESO_SERVICEACCOUNT}
            namespace: ${SAAS_ESO_NAMESPACE}
