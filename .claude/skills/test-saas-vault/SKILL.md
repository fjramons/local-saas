---
name: test-saas-vault
description: Re-runs the saas vault tests (unit + real E2E) after modifying any file under services/vault/, services/gitlab/lib/vault_integration.sh, or lib/common.sh. Use whenever state.sh, secrets.sh, cluster.sh, versions.sh, operators.sh, tls.sh, init.sh, install.sh, credentials.sh, doctor.sh, integration_common.sh, gitlab_integration.sh, eso_integration.sh, vault_integration.sh, or values/*.yaml.tpl change.
---

# Testing `saas vault`

This repo has two test tiers for `services/vault/` (plus the small `services/gitlab/lib/vault_integration.sh` counterpart):

1. `tests/vault/unit/test-argparse-values.sh`: fast (<1s), no real cluster, mocks `kubectl`/`helm`/`kind_cluster`. Includes the order-independence proof for `integrate gitlab` (asserts zero Vault-mutating calls happen until both preflight conditions are met, via call-counters on stubbed `_saas_vault_bao_exec`/`_saas_vault_bao_exec_stdin`). Run this first, on every iteration.
2. `tests/vault/e2e/run-tests.sh`: real, creates a disposable `kind` cluster and installs OpenBao for real, with genuine automated `bao operator init`/unseal. Takes several minutes. Run this before signing off on any change to the real install (`install.sh`, `init.sh`, `tls.sh`, `operators.sh`, `cluster.sh`, `credentials.sh`, `doctor.sh`, `integration_common.sh`, `gitlab_integration.sh`, `eso_integration.sh`, or `values/*.yaml.tpl`).

## What the E2E suite checks

Default phases (run every time):

1. **dev-install**: a real `saas vault install --cluster-mode kind --mode dev --tls self-signed --non-interactive -y`. Checks the pod genuinely comes up unsealed AND initialized (fully automated, no manual `bao operator init`/unseal), that `curl` against the ingress with the right `Host` header reaches Vault itself (not ingress-nginx's own error page - see CLAUDE.md on `service_registration "kubernetes" {}`), that `saas vault credentials --reveal-root-token` prints a token, and that the token genuinely authenticates against the API (`/v1/auth/token/lookup-self`).
2. **doctor**: depends on `dev-install`. Deliberately deletes the `unseal-keys` Secret and force-restarts the pod (the same kind of drift a host reboot can leave behind), checks `saas vault doctor` detects it, then that `--fix` re-unseals from the saved local keys, confirmed live.
3. **credentials-defaults**: depends on `dev-install`. Confirms the bare `credentials` command never prints the root token or unseal key shares (only the explanatory "hidden by default" notice, which legitimately mentions those words - the test matches only the actual data-printing lines, e.g. `^Root token:`, not any mention of the words), and that it still prints the URL.
4. **up-down**: depends on `dev-install`. Runs `saas vault down` then `saas vault up`. Does NOT assert the root token/unseal keys stay byte-identical (verified live that kind's default `local-path` storage does not reliably give a fresh PVC its old data back, see CLAUDE.md) - the actual invariant checked is that the instance ends up initialized and unsealed again with zero manual input either way, and that the (possibly fresh) root token authenticates against the API.
5. **integrate-gitlab-order-independence**: no dependency on any gitlab cluster existing at all. Runs `saas vault integrate gitlab` against a nonexistent kubeconfig context and asserts it fails cleanly AND that Vault's own `bao auth list`/`bao secrets list` are byte-identical before and after - the literal, live proof of the two-phase design's core safety property.

Opt-in only phases (`--only PHASE[,PHASE...]`, never part of the default run, each installs a second real service). `--only` accepts a comma-separated list, run in a single process, which is how `eso-round-trip` is meant to be combined with `integrate-gitlab-full`: selecting `eso-round-trip` on its own is rejected up front with a clear message, since nothing would have stood up the gitlab cluster it needs. Likewise, `integrate-gitlab-full` needs Vault's own release, which only `dev-install` creates: when `--only` is given, `integrate-gitlab-full` without `dev-install` in the same list is also rejected up front (with `--only` omitted, the default phases - including `dev-install` - already run first, so this only matters when narrowing with `--only`).

6. **prod-ha**: installs a SEPARATE release (`vaulte2eha`), 3-replica HA Raft, checks all 3 pods report unsealed and `bao operator raft list-peers` shows 3 voters. Cleaned up by the unified end-of-script trap (honors `--keep`).
7. **integrate-gitlab-full**: installs a REAL `saas gitlab` release in a second disposable kind cluster, then exercises the complete two-sided handshake for real: `saas vault integrate gitlab` (phase A, renders the reviewer manifest) → `saas gitlab integrate vault` (applies it) → `saas vault integrate gitlab` again (phase B, seeds gitlab's REAL live PostgreSQL/MinIO/etc. credentials) → `saas gitlab integrate vault` again (applies the final `SecretStore`/`ExternalSecret`). Confirms the seeded KV value matches gitlab's actual live credential, not a placeholder. The gitlab cluster is left alive until the unified end-of-script trap runs, so `eso-round-trip` can reuse it.
8. **eso-round-trip**: must be selected together with `integrate-gitlab-full` (and, if using `--only`, `dev-install` too) in the same `--only` list (`--only dev-install,integrate-gitlab-full,eso-round-trip`), since it reuses that phase's gitlab cluster and already-applied manifests. Installs a throwaway, test-only External Secrets Operator (never part of the shipped service, see CLAUDE.md's decision on this) and confirms a real Kubernetes `Secret` appears there with the value actually seeded in Vault.

## Prerequisites

- `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst`, `curl` installed.
- `kind_cluster` (`bash-aliases` repo) reachable: nothing to do if your shell already has it loaded; otherwise pass `KIND_CLUSTER_FUNCTIONS`:
  ```bash
  KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
    bash tests/vault/e2e/run-tests.sh
  ```
- No kind cluster named `vaulte2e` (or `vaulte2eha`/`gitlabe2e` for the opt-in phases) already existing from a previous interrupted run (see "Manual cleanup").
- Takes several minutes: creates a real kind cluster, installs MetalLB (via `kind_cluster`), ingress-nginx, cert-manager, Stakater Reloader, and the full OpenBao chart with genuine `bao operator init`.
- `integrate-gitlab-full`/`eso-round-trip` additionally install a full `saas gitlab` release (and, for the latter, a throwaway ESO) in a SECOND cluster: only run these deliberately, never as part of a quick iteration loop.

## How to run it

```bash
bash tests/vault/unit/test-argparse-values.sh

bash tests/vault/e2e/run-tests.sh                                # default suite (dev-install, doctor, credentials-defaults, up-down, integrate-gitlab-order-independence)
bash tests/vault/e2e/run-tests.sh --only dev-install              # a single phase
bash tests/vault/e2e/run-tests.sh --keep                          # don't tear down at the end, for inspection
bash tests/vault/e2e/run-tests.sh --only prod-ha                  # opt-in, heavy: 3-replica HA Raft
bash tests/vault/e2e/run-tests.sh --only dev-install,integrate-gitlab-full,eso-round-trip # opt-in, heavy: full combo
```

## How to read the results

- A `FAIL` on "the ingress serves /v1/sys/health" together with nginx logging `does not have any active Endpoint` (check with `--keep` + `kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller`) almost always means the Raft `config` HCL is missing `service_registration "kubernetes" {}` (see CLAUDE.md) - OpenBao never labels itself as the active/leader pod, so the chart's `-active` Service (what ingress targets by default) never gets an Endpoint, and nginx returns its OWN generic 503, not a response from Vault.
- A `FAIL` on "the root token authenticates against the API" with an empty/garbled response usually means `global.tlsDisable: false` isn't set in the values overlay: without it, every `BAO_ADDR` the chart injects defaults to plain HTTP, and `bao` calls made via `kubectl exec` (inheriting the container's own env) fail with "sent an HTTP request to an HTTPS server" (see CLAUDE.md).
- A `FAIL` on "ends up initialized and unsealed automatically" after `up` is a real regression in `init.sh`'s `_saas_vault_init_ensure`: it means the pod's live `.initialized` status stopped being checked before deciding whether to reuse saved keys vs. generate fresh ones, so a fresh (uninitialized) store is getting old, now-useless key shares posted at it forever instead of a real re-init.
- A `FAIL` in `integrate-gitlab-order-independence` on "auth methods/secrets engines untouched" is a serious regression: it means the two-phase preflight design broke and Vault's own configuration is now being mutated even when the target GitLab cluster was never confirmed ready, exactly the failure mode the whole two-phase design exists to prevent.
- A `FAIL` in `prod-ha` on "all 3 replicas report unsealed" or "Raft cluster has 3 voters" that persists across the tool's own single-node default kind cluster is likely the chart's own default REQUIRED pod anti-affinity resurfacing (see CLAUDE.md): confirm with `kubectl -n <ns> describe pod <fullname>-1` looking for `FailedScheduling ... didn't match pod anti-affinity rules`, permanent and non-timing, not a slow convergence.

## Manual cleanup

If the script is interrupted before the cleanup `trap` runs:

```bash
saas vault delete vaulte2e --purge-storage -y      # if saas.sh is still loaded in your shell
saas vault delete vaulte2eha --purge-storage -y    # if prod-ha was interrupted
saas gitlab delete gitlabe2e --purge-storage -y     # if integrate-gitlab-full/eso-round-trip was interrupted
helm uninstall external-secrets --namespace external-secrets   # if eso-round-trip was interrupted
# or, directly:
kind delete cluster --name vaulte2e
kind delete cluster --name vaulte2eha
kind delete cluster --name gitlabe2e
```

## After changes to `services/vault/` (or `services/gitlab/lib/vault_integration.sh`)

1. `bash -n` on any file touched.
2. If the change only touches flag parsing, `state.sh`, `secrets.sh`, `_saas_vault_fullname`, or the preflight logic in `gitlab_integration.sh`/`eso_integration.sh`: `bash tests/vault/unit/test-argparse-values.sh` first (instant).
3. If the change touches `install.sh`, `init.sh`, `tls.sh`, `operators.sh`, `cluster.sh`, `credentials.sh`, `doctor.sh`, `integration_common.sh`, `gitlab_integration.sh`, `eso_integration.sh`, `vault_integration.sh`, or any `values/*.yaml.tpl`: validate first with `helm template` where applicable (no real cluster, see CLAUDE.md's "Manual testing" section, adapted for `services/vault/values/`) and then run the full default E2E suite. A change to `tls.sh` (the internal PKI chain) or `values/unseal.yaml.tpl` (the unseal-sidecar/volume wiring) specifically needs a real `dev-install` run at minimum, since these are exactly the parts most likely to silently break init/unseal automation.
4. A change touching the GitLab or ESO integration (`gitlab_integration.sh`, `eso_integration.sh`, `vault_integration.sh`, or any `gitlab-*.yaml.tpl`/`eso-*.yaml.tpl`) needs `--only integrate-gitlab-order-independence` at minimum (fast, default), and `--only dev-install,integrate-gitlab-full` (heavy, opt-in) before signing off on anything affecting the live-secret-seeding path.
5. If the change affects some subcommand's `--help`, also check by hand that it's still consistent with the real options (the test doesn't verify the help text's content).
