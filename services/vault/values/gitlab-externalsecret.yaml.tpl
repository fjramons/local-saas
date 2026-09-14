# Applied into the GITLAB cluster, via 'saas gitlab integrate vault'. Four ExternalSecrets, one
# per datastore Secret 'saas gitlab' itself would otherwise create natively (see
# services/gitlab/lib/datastore.sh's _saas_gitlab_datastore_secrets_apply): same target Secret
# names and keys, byte-for-byte, so gitlab's own values templates never need to know their
# credentials came from Vault instead of being generated in-cluster. Variables substituted by
# envsubst.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-gitlab-datastore-psql
  namespace: ${SAAS_GITLAB_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_GITLAB_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_GITLAB_RELEASE}-datastore-psql
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef: {key: psql, property: username}
    - secretKey: password
      remoteRef: {key: psql, property: password}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-gitlab-datastore-minio
  namespace: ${SAAS_GITLAB_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_GITLAB_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_GITLAB_RELEASE}-datastore-minio
    creationPolicy: Owner
  data:
    - secretKey: rootUser
      remoteRef: {key: minio, property: rootUser}
    - secretKey: rootPassword
      remoteRef: {key: minio, property: rootPassword}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-gitlab-datastore-objectstore
  namespace: ${SAAS_GITLAB_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_GITLAB_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_GITLAB_RELEASE}-datastore-objectstore
    creationPolicy: Owner
  data:
    - secretKey: connection
      remoteRef: {key: objectstore, property: connection}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${SAAS_VAULT_RELEASE}-vault-gitlab-datastore-s3cfg
  namespace: ${SAAS_GITLAB_NAMESPACE}
spec:
  secretStoreRef: {name: ${SAAS_VAULT_RELEASE}-vault-${SAAS_GITLAB_RELEASE}, kind: ClusterSecretStore}
  target:
    name: ${SAAS_GITLAB_RELEASE}-datastore-s3cfg
    creationPolicy: Owner
  data:
    - secretKey: config
      remoteRef: {key: s3cfg, property: config}
