# Applied into the GITLAB cluster, via 'saas gitlab integrate postgres'. Byte-identical name/keys/
# type to what services/gitlab/lib/datastore.sh's own _saas_gitlab_datastore_psql_secret_apply
# already creates for GitLab's private PostgreSQL, so GitLab's chart values (global.psql.*) need no
# translation whether the database is internal or, via --database external, this shared postgres.
# Variables substituted by envsubst.
apiVersion: v1
kind: Secret
metadata:
  name: ${SAAS_GITLAB_RELEASE}-datastore-psql
type: kubernetes.io/basic-auth
stringData:
  username: gitlab
  password: ${SAAS_POSTGRES_GITLAB_PASSWORD}
