# Applied into the GITLAB cluster, via 'saas gitlab integrate vault', once Vault's own side of
# the integration (KV engine, Kubernetes auth trust, policy/role) is confirmed ready. Points
# External Secrets Operator at this Vault instance using ESO's generic 'vault' provider (OpenBao
# is Vault-API-compatible, no OpenBao-specific ESO provider is needed).
#
# Deliberately a ClusterSecretStore, not a namespaced SecretStore: verified live that ESO's own
# admission webhook REJECTS a namespaced SecretStore whose auth.kubernetes.serviceAccountRef
# points at a different namespace than the SecretStore itself ("namespace should either be empty
# or match the namespace of the SecretStore"), which is exactly this case, since ESO's own
# controller ServiceAccount normally lives in ESO's own namespace (--eso-namespace), not in every
# consuming namespace. ClusterSecretStore is cluster-scoped and explicitly allows referencing a
# ServiceAccount in any namespace, which is the whole point of it existing. Named per-GITLAB-
# release (not just per-Vault-release) since ClusterSecretStore objects share one cluster-wide
# namespace of names, unlike a per-namespace SecretStore. Variables substituted by envsubst.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-ca
  namespace: ${SAAS_GITLAB_NAMESPACE}
data:
  ca.crt: ${SAAS_VAULT_CA_BUNDLE_B64}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_GITLAB_RELEASE}
spec:
  provider:
    vault:
      server: ${SAAS_VAULT_URL}
      path: gitlab/${SAAS_GITLAB_RELEASE}
      version: v2
      caProvider:
        type: Secret
        name: ${SAAS_VAULT_RELEASE}-vault-ca
        namespace: ${SAAS_GITLAB_NAMESPACE}
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${SAAS_VAULT_RELEASE}-gitlab-${SAAS_GITLAB_RELEASE}-role
          serviceAccountRef:
            name: ${SAAS_ESO_SERVICEACCOUNT}
            namespace: ${SAAS_ESO_NAMESPACE}
