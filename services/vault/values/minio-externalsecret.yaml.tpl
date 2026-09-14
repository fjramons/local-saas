# Applied into the MINIO cluster, via 'saas minio integrate vault'. One ExternalSecret targeting
# the SAME Secret MinIO's own install already creates ('<release>-credentials', see
# services/minio/lib/backend.sh's _saas_minio_secrets_apply): once ESO syncs it, a credential
# rotation done in Vault reaches MinIO for real (MinIO still needs restarting to pick up a changed
# env var, see 'saas minio doctor'/'saas minio integrate vault --help'), not just a wiring demo.
# Variables substituted by envsubst.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-minio-credentials
  namespace: ${SAAS_MINIO_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_MINIO_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_MINIO_RELEASE}-credentials
    creationPolicy: Owner
  data:
    - secretKey: rootUser
      remoteRef: {key: minio, property: rootUser}
    - secretKey: rootPassword
      remoteRef: {key: minio, property: rootPassword}
