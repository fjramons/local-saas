---
name: test-saas-minio
description: Re-runs the saas minio tests (unit + real E2E) after modifying any file under services/minio/, services/gitlab/lib/minio_integration.sh, services/vault/lib/minio_integration.sh, services/cluster/, or lib/common.sh. Use whenever state.sh, cluster.sh, backend.sh, tls.sh, install.sh, credentials.sh, doctor.sh, bucket.sh, integration_common.sh, vault_integration.sh, gitlab_integration.sh, values/*.yaml.tpl, or the shared _saas_cluster_backend_* functions (lib/common.sh) change. See also .claude/skills/test-saas-cluster.
---

# Testing `saas minio`

This repo has two test tiers for `services/minio/` (plus the small `services/gitlab/lib/minio_integration.sh` and `services/vault/lib/minio_integration.sh` counterparts):

1. `tests/minio/unit/test-argparse-values.sh`: fast (<1s), no real cluster, mocks `kubectl`/`kind_cluster`. Includes the order-independence proof for `integrate gitlab` (asserts zero MinIO-mutating calls happen until the target GitLab cluster is confirmed reachable, via a call-counter on `_saas_minio_init_buckets`) and the apply-only tests for `integrate vault`. Run this first, on every iteration.
2. `tests/minio/e2e/run-tests.sh`: real, creates a disposable `kind` cluster and installs MinIO for real. Takes several minutes. Run this before signing off on any change to the real install (`install.sh`, `backend.sh`, `tls.sh`, `cluster.sh`, `credentials.sh`, `doctor.sh`, `bucket.sh`, `integration_common.sh`, `vault_integration.sh`, `gitlab_integration.sh`, or `values/*.yaml.tpl`).

## What the E2E suite checks

Default phases (run every time):

1. **dev-install**: a real `saas minio install --cluster-mode kind --mode dev --tls self-signed --bucket testbucket --non-interactive -y`. Checks the pod comes up Ready, that `saas minio credentials --verify` authenticates against the live instance, a real `bucket create`/`list`/`rm` round trip via the pinned `mc` image, and that `saas minio doctor` reports a clean install.
2. **doctor**: depends on `dev-install`. Deliberately drifts the `<release>-credentials` Secret's password away from the pod's real one (the same kind of drift a host reboot can leave behind), checks `saas minio doctor` detects it without `--fix`, then that `--fix` reconciles it, confirmed against the pod's own live env.
3. **up-down**: depends on `dev-install`. Runs `saas minio down` then `saas minio up`, confirms the pre-created bucket is still there (or idempotently recreated) and credentials still authenticate.

Opt-in only phases (`--only PHASE[,PHASE...]`, never part of the default run, each installs a second real service):

4. **prod-ha**: installs a SEPARATE release (`minioe2eha`), 4-node distributed mode, checks the `StatefulSet` reaches 4 ready replicas.
5. **integrate-vault-full**: installs a real Vault release (`--cluster-mode existing`, into MinIO's own kind cluster, same single-host workaround as the other two suites' own `*-full` phases) and a throwaway ESO, exercises the complete round trip (`saas vault integrate minio` → `saas minio integrate vault` applies the reviewer manifest → `saas vault integrate minio` again seeds MinIO's REAL live root credentials → `saas minio integrate vault` again applies the final `SecretStore`/`ExternalSecret`), and confirms MinIO's OWN `<release>-credentials` Secret ends up owned by the `ExternalSecret` with a real synced value.
6. **integrate-gitlab-full**: installs a real `saas gitlab install --object-storage external` release (`--cluster-mode existing`, same single-host workaround), running the full one-shot handshake (`saas minio integrate gitlab` creates GitLab's expected buckets and renders the datastore Secrets manifest → `saas gitlab integrate minio` applies it → `saas gitlab install --object-storage external` starts with ZERO private MinIO of its own). Confirms no `<gitlab-release>-minio` Deployment was created, that GitLab's datastore Secret carries MinIO's real root user, and that the `registry` bucket exists on the shared MinIO.

`doctor`/`up-down` depend on `dev-install` having left the release alive. `--only` accepts a comma-separated list, needed for `integrate-vault-full`/`integrate-gitlab-full` when narrowing (they reuse the kind cluster `dev-install` creates).

## Prerequisites

- `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst` installed.
- `kind_cluster` (`bash-aliases` repo) reachable: nothing to do if your shell already has it loaded; otherwise pass `KIND_CLUSTER_FUNCTIONS`:
  ```bash
  KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
    bash tests/minio/e2e/run-tests.sh
  ```
- No kind cluster named `minioe2e` (or `minioe2eha` for the opt-in HA phase) already existing from a previous interrupted run (see "Manual cleanup").
- Takes several minutes: creates a real kind cluster, installs MetalLB (via `kind_cluster`), ingress-nginx, cert-manager, and MinIO.
- `integrate-vault-full`/`integrate-gitlab-full` additionally install a full Vault or GitLab release (and, for the former, a throwaway ESO) INTO the same cluster: only run these deliberately, never as part of a quick iteration loop.

## How to run it

```bash
bash tests/minio/unit/test-argparse-values.sh

bash tests/minio/e2e/run-tests.sh                                # default suite (dev-install, doctor, up-down)
bash tests/minio/e2e/run-tests.sh --only dev-install              # a single phase
bash tests/minio/e2e/run-tests.sh --keep                          # don't tear down at the end, for inspection
bash tests/minio/e2e/run-tests.sh --only prod-ha                  # opt-in, heavy: 4-node distributed
bash tests/minio/e2e/run-tests.sh --only dev-install,integrate-vault-full   # opt-in, heavy
bash tests/minio/e2e/run-tests.sh --only dev-install,integrate-gitlab-full  # opt-in, heavy
```

## How to read the results

- A `FAIL` on "credentials --verify" almost always means the Ingress/Certificate never became Ready, or the throwaway `mc` pod (`kubectl run --rm -i`) couldn't resolve the in-cluster Service address; check with `--keep` + `kubectl -n <ns> get ingress,certificate,pods`.
- A `FAIL` in `integrate-gitlab-full` on "no private MinIO Deployment was created" is a real, serious regression: it means `--object-storage external` stopped actually skipping `_saas_gitlab_datastore_minio_internal_apply` in `services/gitlab/lib/datastore.sh`, defeating the entire point of the flag.
- A `FAIL` in `integrate-vault-full` on "MinIO's OWN credentials Secret was synced by ESO" with `owner: 'none'` usually means the `ExternalSecret`'s target name in `services/vault/values/minio-externalsecret.yaml.tpl` no longer matches `services/minio/lib/backend.sh`'s `_saas_minio_secrets_apply` output name (`<release>-credentials`): check both stayed in sync.
- A `FAIL` in `dev-install` on the bucket round trip with an `mc: command not found`-style error means the pinned `_SAAS_MC_IMAGE` constant (`lib/common.sh`) doesn't actually contain the `mc` binary at that tag; re-verify against `quay.io/minio/mc` directly.

## Manual cleanup

If the script is interrupted before the cleanup `trap` runs:

```bash
saas minio delete minioe2e --purge-storage -y      # if saas.sh is still loaded in your shell
saas minio delete minioe2eha --purge-storage -y    # if prod-ha was interrupted
saas vault delete vaulte2emin --purge-storage -y   # if integrate-vault-full was interrupted
saas gitlab delete gitlabe2emin --purge-storage -y # if integrate-gitlab-full was interrupted
helm uninstall external-secrets --namespace external-secrets   # if integrate-vault-full was interrupted
# or, directly:
kind delete cluster --name minioe2e
kind delete cluster --name minioe2eha
```

## After changes to `services/minio/`

1. `bash -n` on any file touched.
2. If the change only touches flag parsing, `state.sh`, bucket-name validation, or the preflight logic in `vault_integration.sh`/`gitlab_integration.sh`: `bash tests/minio/unit/test-argparse-values.sh` first (instant).
3. If the change touches `install.sh`, `backend.sh`, `tls.sh`, `cluster.sh`, `credentials.sh`, `doctor.sh`, `bucket.sh`, `integration_common.sh`, `vault_integration.sh`, `gitlab_integration.sh`, or any `values/*.yaml.tpl`: run the full default E2E suite.
4. A change touching the GitLab integration (`gitlab_integration.sh` on either side, `values/gitlab-datastore-secrets.yaml.tpl`, or `services/gitlab/lib/datastore.sh`'s internal/external split) needs `--only dev-install,integrate-gitlab-full` (heavy, opt-in) before signing off, AND a re-run of `tests/gitlab/unit/test-argparse-values.sh`/`tests/gitlab/e2e/run-tests.sh --only dev-install` to confirm the default (`internal`) path has no regression.
5. A change touching the Vault integration (`vault_integration.sh` on either side, or `services/vault/values/minio-*.yaml.tpl`) needs `bash tests/vault/unit/test-argparse-values.sh` (the order-independence cases live there) and `--only dev-install,integrate-vault-full` (heavy, opt-in).
6. If the change affects some subcommand's `--help`, also check by hand that it's still consistent with the real options (the test doesn't verify the help text's content).
