apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_GITLAB_RELEASE}-datastore-minio
type: Opaque
stringData:
  rootUser: ${SAAS_MINIO_ROOT_USER}
  rootPassword: ${SAAS_MINIO_ROOT_PASSWORD}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_GITLAB_RELEASE}-datastore-objectstore
type: Opaque
stringData:
  connection: |
    provider: AWS
    region: us-east-1
    aws_access_key_id: ${SAAS_MINIO_ROOT_USER}
    aws_secret_access_key: ${SAAS_MINIO_ROOT_PASSWORD}
    host: ${SAAS_MINIO_HOST}
    endpoint: ${SAAS_MINIO_ENDPOINT}
    path_style: true
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_GITLAB_RELEASE}-datastore-s3cfg
type: Opaque
stringData:
  config: |
    [default]
    access_key = ${SAAS_MINIO_ROOT_USER}
    secret_key = ${SAAS_MINIO_ROOT_PASSWORD}
    host_base = ${SAAS_MINIO_HOST}
    host_bucket = ${SAAS_MINIO_HOST}
    use_https = ${SAAS_MINIO_USE_HTTPS}
    check_ssl_certificate = ${SAAS_MINIO_USE_HTTPS}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_GITLAB_RELEASE}-datastore-registry-storage
type: Opaque
stringData:
  config: |
    s3:
      bucket: registry
      v4auth: true
      regionendpoint: ${SAAS_MINIO_ENDPOINT}
      region: minio
      accesskey: ${SAAS_MINIO_ROOT_USER}
      secretkey: ${SAAS_MINIO_ROOT_PASSWORD}
      secure: ${SAAS_MINIO_SECURE}
      pathstyle: true
      checksum_disabled: true
    redirect:
      disable: true
