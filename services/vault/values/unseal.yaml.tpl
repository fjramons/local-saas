# Always-applied layer (both --mode dev and --mode prod), on top of dev.yaml.tpl/prod.yaml.tpl.
# Carries every list-valued key under 'server' (volumes, volumeMounts, extraContainers): Helm's
# '-f' layering deep-merges maps but REPLACES lists wholesale at the same key path, so the TLS
# mount and the unseal-sidecar container have to live in the SAME layer as each other (and be
# entirely absent from the base layer) to avoid one layer silently clobbering the other's list.
#
# The unseal-sidecar script is adapted from a real production OpenBao deployment's own approach
# (portable there, no vendor lock-in), simplified: polls the local API's seal status and posts each
# mounted key share to /v1/sys/unseal, repeating forever so a pod restart (which reseals it) is
# picked back up automatically. Only ever sees a THRESHOLD-sized subset of the real key shares,
# mounted read-only from the 'unseal-keys' Secret (services/vault/lib/init.sh creates/refreshes
# it from the local, out-of-cluster keys file, which stays the source of truth); the root token is
# never mounted anywhere in-cluster. See CLAUDE.md for the documented trade-off this implies.
server:
  extraEnvironmentVars:
    BAO_CACERT: /openbao/tls/ca.crt
  volumes:
    - name: vault-tls
      secret:
        secretName: ${SAAS_RELEASE}-vault-int-tls
    - name: unseal-keys
      secret:
        secretName: ${SAAS_RELEASE}-vault-unseal-keys
        optional: true
  volumeMounts:
    - name: vault-tls
      mountPath: /openbao/tls
      readOnly: true
  extraContainers:
    - name: unseal-sidecar
      image: curlimages/curl:8.11.0
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          ulimit -c 0
          API="https://127.0.0.1:8200"
          CACERT="/openbao/tls/ca.crt"

          while [ ! -f /etc/unseal-keys/key1 ]; do sleep 2; done

          unseal_once() {
            sealed="$(curl -sS --cacert "$CACERT" "${API}/v1/sys/seal-status" 2>/dev/null | sed -n 's/.*"sealed":\([a-z]*\).*/\1/p')"
            [ "$sealed" = "false" ] && return 0
            for f in /etc/unseal-keys/key*; do
              [ -f "$f" ] || continue
              key="$(cat "$f")"
              curl -sS --cacert "$CACERT" --request PUT --data "{\"key\":\"${key}\"}" "${API}/v1/sys/unseal" >/dev/null 2>&1 || true
            done
          }

          while true; do
            until curl -sS --cacert "$CACERT" -o /dev/null "${API}/v1/sys/seal-status" 2>/dev/null; do sleep 2; done
            unseal_once
            sleep 15
          done
      volumeMounts:
        - name: vault-tls
          mountPath: /openbao/tls
          readOnly: true
        - name: unseal-keys
          mountPath: /etc/unseal-keys
          readOnly: true
