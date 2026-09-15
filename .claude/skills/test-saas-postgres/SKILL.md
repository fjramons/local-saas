---
name: test-saas-postgres
description: Re-runs the saas postgres tests (unit + real E2E) after modifying any file under services/postgres/, services/gitlab/lib/postgres_integration.sh, services/vault/lib/postgres_integration.sh, services/cluster/, or lib/common.sh. Use whenever state.sh, cluster.sh, expose.sh, backend.sh, tls.sh, install.sh, credentials.sh, doctor.sh, database.sh, integration_common.sh, vault_integration.sh, gitlab_integration.sh, values/*.yaml.tpl, or the shared _saas_cluster_backend_*/_saas_ensure_cnpg_operator functions (lib/common.sh) change. See also .claude/skills/test-saas-cluster.
---

# Testing `saas postgres`

This repo has two test tiers for `services/postgres/` (plus the small `services/gitlab/lib/postgres_integration.sh` and `services/vault/lib/postgres_integration.sh` counterparts):

1. `tests/postgres/unit/test-argparse-values.sh`: fast (<1s), no real cluster, mocks `kubectl`/`kind_cluster`. Includes the order-independence proof for `integrate gitlab` (asserts zero postgres-mutating calls happen until the target GitLab cluster is confirmed reachable, via a call-counter on `_saas_postgres_database_create_internal`) and the apply-only tests for `integrate vault`. Run this first, on every iteration.
2. `tests/postgres/e2e/run-tests.sh`: real, creates a disposable `kind` cluster and installs PostgreSQL for real. Takes several minutes. Run this before signing off on any change to the real install (`install.sh`, `backend.sh`, `tls.sh`, `cluster.sh`, `expose.sh`, `credentials.sh`, `doctor.sh`, `database.sh`, `integration_common.sh`, `vault_integration.sh`, `gitlab_integration.sh`, or `values/*.yaml.tpl`).

## What the E2E suite checks

Default phases (run every time):

1. **dev-install**: a real `saas postgres install --cluster-mode kind --mode dev --tls self-signed --database testdb --non-interactive -y`. Checks the pod comes up Ready, and, the single most safety-critical assertion in this whole suite, that a plaintext (`sslmode=disable`) connection attempt is REJECTED while a real (`sslmode=require`) one with the correct password succeeds: this is what actually proves `hostssl`-only enforcement works, not just that TLS is configured. Also checks `saas postgres credentials --verify`, `database list`, and a clean `saas postgres doctor`.
2. **doctor**: depends on `dev-install`. Deliberately changes the admin role's REAL database password directly (not just the Secret: a Secret-only edit doesn't actually simulate drift here, since Kubernetes never restarts a pod just because its Secret changed, and PostgreSQL's own running password is independent of it). Checks `saas postgres doctor` detects the mismatch without `--fix`, then that `--fix` reconciles it, confirmed by a real re-authentication.
3. **database**: depends on `dev-install`. Exercises `database create/list/drop`, including `--owner`, confirms the companion `<release>-<owner>-credentials` Secret exists and that role can genuinely connect to and own its database, and confirms `create --owner` is idempotent on a re-run.
4. **up-down**: depends on `dev-install`. Runs `saas postgres down` then `saas postgres up`, confirms the pre-created database is still there (or idempotently recreated), credentials still authenticate, and TLS enforcement still holds.

Opt-in only phases (`--only PHASE[,PHASE...]`, never part of the default run, each installs a second real service):

5. **prod-ha**: installs a SEPARATE release (`postgrese2eha`), CloudNativePG-managed 3-instance HA, checks the `Cluster` reports `Cluster in healthy state`, re-confirms TLS enforcement (plaintext rejected, real connection succeeds) against the CNPG-managed instance, and confirms `database create` actually works there (the CNPG bootstrap owner role starts with no `CREATEDB`/`CREATEROLE`, so this also re-verifies `_saas_postgres_prod_apply`'s own grant step).
6. **integrate-vault-full**: installs a real Vault release (`--cluster-mode existing`, into postgres's own kind cluster, same single-host workaround as the other three suites' own `*-full` phases) and a throwaway ESO, exercises the complete round trip (`saas vault integrate postgres` → `saas postgres integrate vault` applies the reviewer manifest → `saas vault integrate postgres` again seeds postgres's REAL live admin credentials → `saas postgres integrate vault` again applies the final `SecretStore`/`ExternalSecret`), and confirms postgres's OWN `<release>-credentials` Secret ends up owned by the `ExternalSecret` with a real synced value.
7. **integrate-gitlab-full**: installs a real `saas gitlab install --database external` release (`--cluster-mode existing`, same single-host workaround), running the full one-shot handshake (`saas postgres integrate gitlab` creates GitLab's expected role/databases and renders the datastore Secret + connection info → `saas gitlab integrate postgres` applies the Secret and folds the host/port into GitLab's own state → `saas gitlab install --database external` starts with ZERO private PostgreSQL of its own). Confirms no `<gitlab-release>-postgresql` StatefulSet was created, that GitLab's `gitlabhq_production`/`gitlabhq_production_ci` databases exist on the shared postgres, and that GitLab's datastore Secret carries the real shared `gitlab` role password.

`doctor`/`database`/`up-down` depend on `dev-install` having left the release alive. `--only` accepts a comma-separated list, needed for `integrate-vault-full`/`integrate-gitlab-full` when narrowing (they reuse the kind cluster `dev-install` creates).

## Prerequisites

- `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst` installed.
- `kind_cluster` (`bash-aliases` repo) reachable: nothing to do if your shell already has it loaded; otherwise pass `KIND_CLUSTER_FUNCTIONS`:
  ```bash
  KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
    bash tests/postgres/e2e/run-tests.sh
  ```
- No kind cluster named `postgrese2e` (or `postgrese2eha` for the opt-in HA phase) already existing from a previous interrupted run (see "Manual cleanup").
- Takes several minutes: creates a real kind cluster, installs cert-manager and PostgreSQL (`prod-ha` additionally installs the CloudNativePG operator).
- `integrate-vault-full`/`integrate-gitlab-full` additionally install a full Vault or GitLab release (and, for the former, a throwaway ESO) INTO the same cluster: only run these deliberately, never as part of a quick iteration loop.

## How to run it

```bash
bash tests/postgres/unit/test-argparse-values.sh

bash tests/postgres/e2e/run-tests.sh                                 # default suite (dev-install, doctor, database, up-down)
bash tests/postgres/e2e/run-tests.sh --only dev-install               # a single phase
bash tests/postgres/e2e/run-tests.sh --keep                           # don't tear down at the end, for inspection
bash tests/postgres/e2e/run-tests.sh --only prod-ha                   # opt-in, heavy: CloudNativePG 3-instance HA
bash tests/postgres/e2e/run-tests.sh --only dev-install,integrate-vault-full    # opt-in, heavy
bash tests/postgres/e2e/run-tests.sh --only dev-install,integrate-gitlab-full   # opt-in, heavy
```

## How to read the results

- A `FAIL` on "a plaintext (sslmode=disable) connection is REJECTED" is a real, serious regression: it means `hostssl`-only enforcement broke. Check `services/postgres/lib/backend.sh`'s `00-hostssl.sh` initdb script (dev mode) still PREPENDS both `hostnossl all all all reject` AND `hostssl all all all scram-sha-256` before the image's own default rules, in that order; a live reinstall is required to see the effect (the script only runs against a fresh, empty data directory).
- A `FAIL` on the same check in `prod-ha` means `spec.postgresql.pg_hba` no longer carries the `hostnossl` entry on the CNPG `Cluster` CR (`_saas_postgres_prod_apply`), or CNPG's own ordering of operator-supplied vs. built-in `pg_hba` rules changed in a newer chart version (re-verify live against the installed CRD, same discipline as every other CNPG-specific finding in this repo's CLAUDE.md).
- A `FAIL` on "database create works against the CNPG-managed cluster" means the `ALTER ROLE ... CREATEDB CREATEROLE` grant step in `_saas_postgres_prod_apply` isn't running or isn't taking effect; check it's still using the primary pod's LOCAL peer-authenticated connection as the real `postgres` superuser (no password ever needed for that path).
- A `FAIL` in `integrate-gitlab-full` on "no private PostgreSQL StatefulSet was created" is a real, serious regression: it means `--database external` stopped actually skipping the StatefulSet/CNPG `Cluster` block in `services/gitlab/lib/datastore.sh`/`datastore-ha.sh`, defeating the entire point of the flag.
- A `FAIL` in `integrate-vault-full` on "postgres's OWN credentials Secret was synced by ESO" with `owner: 'none'` usually means the `ExternalSecret`'s target name in `services/vault/values/postgres-externalsecret.yaml.tpl` no longer matches `services/postgres/lib/backend.sh`'s `_saas_postgres_secrets_apply` output name (`<release>-credentials`): check both stayed in sync.
- A `FAIL` on `credentials --verify`/`database` commands with a "permission denied to create database/role" error usually means the CNPG `CREATEDB`/`CREATEROLE` grant (see above) silently failed, or someone changed the default admin username back to `postgres` (reserved for CNPG's own superuser, see `install.sh`'s `_saas_postgres_valid_admin_username`).

## Manual cleanup

If the script is interrupted before the cleanup `trap` runs:

```bash
saas postgres delete postgrese2e --purge-storage -y      # if saas.sh is still loaded in your shell
saas postgres delete postgrese2eha --purge-storage -y    # if prod-ha was interrupted
saas vault delete vaulte2epg --purge-storage -y          # if integrate-vault-full was interrupted
saas gitlab delete gitlabe2epg --purge-storage -y        # if integrate-gitlab-full was interrupted
helm uninstall external-secrets --namespace external-secrets   # if integrate-vault-full was interrupted
# or, directly:
kind delete cluster --name postgrese2e
kind delete cluster --name postgrese2eha
```

## After changes to `services/postgres/`

1. `bash -n` on any file touched.
2. If the change only touches flag parsing, `state.sh`, identifier validation, or the preflight logic in `vault_integration.sh`/`gitlab_integration.sh`: `bash tests/postgres/unit/test-argparse-values.sh` first (instant).
3. If the change touches `install.sh`, `backend.sh`, `tls.sh`, `cluster.sh`, `expose.sh`, `credentials.sh`, `doctor.sh`, `database.sh`, `integration_common.sh`, `vault_integration.sh`, `gitlab_integration.sh`, or any `values/*.yaml.tpl`: run the full default E2E suite.
4. Any change to `backend.sh`'s TLS/pg_hba logic (either mode) MUST be re-verified live, not just by code review: the `dev-install` phase's plaintext-rejection assertion is the only thing that actually proves enforcement works, and this repo has a real, previously-shipped-looking bug in its history (a loopback-address trust bypass in the plain image's own default `pg_hba.conf`, see CLAUDE.md) that passed a superficial manual check but failed exactly this automated one.
5. A change touching the GitLab integration (`gitlab_integration.sh` on either side, `values/gitlab-datastore-psql-secret.yaml.tpl`, `services/gitlab/values/database-external.yaml.tpl`, or `services/gitlab/lib/datastore.sh`/`datastore-ha.sh`'s internal/external split) needs `--only dev-install,integrate-gitlab-full` (heavy, opt-in) before signing off, AND a re-run of `tests/gitlab/unit/test-argparse-values.sh`/`tests/gitlab/e2e/run-tests.sh --only dev-install` to confirm the default (`internal`) path has no regression.
6. A change touching the Vault integration (`vault_integration.sh` on either side, or `services/vault/values/postgres-*.yaml.tpl`) needs `bash tests/vault/unit/test-argparse-values.sh` (the order-independence cases for vault's OWN integrations live there) and `--only dev-install,integrate-vault-full` (heavy, opt-in).
7. If the change affects some subcommand's `--help`, also check by hand that it's still consistent with the real options (the test doesn't verify the help text's content).
