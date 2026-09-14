# Applied into the MINIO cluster, via 'saas minio integrate vault', once Vault's own side of the
# integration (KV engine, Kubernetes auth trust, policy/role) is confirmed ready. Same shape as
# gitlab-secretstore.yaml.tpl: a ClusterSecretStore (not namespaced, for the same admission-webhook
# reason documented there), named per-MinIO-release since ClusterSecretStore names are cluster-wide.
# Variables substituted by envsubst.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-ca
  namespace: ${SAAS_MINIO_NAMESPACE}
data:
  ca.crt: ${SAAS_VAULT_CA_BUNDLE_B64}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_MINIO_RELEASE}
spec:
  provider:
    vault:
      server: ${SAAS_VAULT_URL}
      path: minio/${SAAS_MINIO_RELEASE}
      version: v2
      caProvider:
        type: Secret
        name: ${SAAS_VAULT_RELEASE}-vault-ca
        namespace: ${SAAS_MINIO_NAMESPACE}
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${SAAS_VAULT_RELEASE}-minio-${SAAS_MINIO_RELEASE}-role
          serviceAccountRef:
            name: ${SAAS_ESO_SERVICEACCOUNT}
            namespace: ${SAAS_ESO_NAMESPACE}
