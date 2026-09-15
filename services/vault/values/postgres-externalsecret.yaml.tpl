# Applied into the POSTGRES cluster, via 'saas postgres integrate vault'. One ExternalSecret
# targeting the SAME Secret postgres's own install already creates ('<release>-credentials', see
# services/postgres/lib/backend.sh's _saas_postgres_secrets_apply): once ESO syncs it, a credential
# rotation done in Vault reaches postgres's Secret for real. Unlike MinIO, that alone does NOT make
# the running database accept the new password (a pod restart doesn't change what a PostgreSQL role
# already stored as its own password): 'saas postgres doctor --fix' is the actual mechanism that
# reconciles it, see 'saas postgres doctor --help'/'saas postgres integrate vault --help'.
# Variables substituted by envsubst.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-postgres-credentials
  namespace: ${SAAS_POSTGRES_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_POSTGRES_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_POSTGRES_RELEASE}-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef: {key: postgres, property: username}
    - secretKey: password
      remoteRef: {key: postgres, property: password}
