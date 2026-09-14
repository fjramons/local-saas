# Generic, gitlab-agnostic counterpart of gitlab-secretstore.yaml.tpl, for 'saas vault integrate
# eso'. Applied into whatever cluster runs the target ESO instance (the user's own; this tool
# never installs ESO itself).
#
# Deliberately a ClusterSecretStore, not a namespaced SecretStore: see the matching comment in
# gitlab-secretstore.yaml.tpl for why (ESO's own admission webhook rejects a namespaced
# SecretStore whose serviceAccountRef points outside its own namespace, which is exactly the
# shape a distinct --target-namespace/--target-serviceaccount pair could produce here too, even
# though it happens to line up by coincidence when both default to "external-secrets"). Variables
# substituted by envsubst.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-ca
  namespace: ${SAAS_TARGET_NAMESPACE}
data:
  ca.crt: ${SAAS_VAULT_CA_BUNDLE_B64}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault
spec:
  provider:
    vault:
      server: ${SAAS_VAULT_URL}
      path: eso-demo
      version: v2
      caProvider:
        type: Secret
        name: ${SAAS_VAULT_RELEASE}-vault-ca
        namespace: ${SAAS_TARGET_NAMESPACE}
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${SAAS_VAULT_RELEASE}-eso-demo-role
          serviceAccountRef:
            name: ${SAAS_TARGET_SERVICEACCOUNT}
            namespace: ${SAAS_TARGET_NAMESPACE}
