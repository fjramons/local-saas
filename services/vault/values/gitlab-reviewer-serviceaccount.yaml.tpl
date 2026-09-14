# Applied into the GITLAB cluster (not Vault's own), via 'saas gitlab integrate vault'.
# Grants Vault's Kubernetes auth method (running in a DIFFERENT cluster) a reviewer identity
# able to validate service account tokens ESO presents, via the standard 'system:auth-delegator'
# ClusterRole (TokenReview/SubjectAccessReview only, no other privilege granted). Namespaced by
# the Vault release name so more than one Vault instance can integrate with the same GitLab
# cluster without colliding. Variables substituted by envsubst.
apiVersion: v1
kind: Namespace
metadata:
  name: vault-integration
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-reviewer
  namespace: vault-integration
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-reviewer
subjects:
  - kind: ServiceAccount
    name: ${SAAS_VAULT_RELEASE}-vault-reviewer
    namespace: vault-integration
roleRef: {kind: ClusterRole, name: system:auth-delegator, apiGroup: rbac.authorization.k8s.io}
---
# Kubernetes 1.24+ no longer auto-creates a token Secret for a ServiceAccount; this explicit
# Secret (annotated per the documented convention) is how one gets provisioned, populated by the
# control plane with 'token'/'ca.crt'/'namespace' keys.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-reviewer-token
  namespace: vault-integration
  annotations:
    kubernetes.io/service-account.name: ${SAAS_VAULT_RELEASE}-vault-reviewer
type: kubernetes.io/service-account-token
