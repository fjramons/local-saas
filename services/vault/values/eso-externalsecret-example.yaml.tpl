# Generic placeholder ExternalSecret for 'saas vault integrate eso': syncs the one example key
# seeded at KV path 'eso-demo' into a plain Kubernetes Secret, purely to prove the wiring works end
# to end. Not gitlab-shaped; adapt 'data'/'target' for whatever the real consumer actually needs.
# Variables substituted by envsubst.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-eso-demo
  namespace: ${SAAS_TARGET_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault, kind: ClusterSecretStore}
  target:
    name: vault-eso-demo
    creationPolicy: Owner
  data:
    - secretKey: example
      remoteRef: {key: eso-demo, property: example}
