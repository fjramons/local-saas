---
name: test-saas-gitlab
description: Re-runs the saas gitlab tests (unit + real E2E) after modifying any file under services/gitlab/ or lib/common.sh. Use whenever install.sh, datastore.sh, datastore-ha.sh, operators.sh, tls.sh, runner.sh, cluster.sh, ssh.sh, state.sh, or values/*.yaml.tpl change.
---

# Testing `saas gitlab`

This repo has two test tiers for `services/gitlab/`:

1. `tests/gitlab/unit/test-argparse-values.sh`: fast (<1s), no real cluster, mocks `kubectl`/`helm`/`kind_cluster`. Run this first, on every iteration.
2. `tests/gitlab/e2e/run-tests.sh`: real, creates a disposable `kind` cluster and installs GitLab for real. Takes several minutes. Run this before signing off on any change to the real install (`install.sh`, `datastore.sh`, `datastore-ha.sh`, `operators.sh`, `tls.sh`, `runner.sh`, `cluster.sh`, `ssh.sh`, or `values/*.yaml.tpl`).

## What the E2E suite checks

1. **dev-install**: a real `saas gitlab install --cluster-mode kind --mode dev --tls self-signed --pages --non-interactive -y` (`--registry` is on by default). Checks that `curl` against the ingress with the right `Host` header responds 200/302 (not just that the command doesn't fail), that `saas gitlab credentials` prints a real password, and that the `gitlab-runner` `Deployment` ends up with ready replicas.
2. **registry**: depends on `dev-install`. Checks the Container Registry API responds at `registry.<domain>/v2/` from inside the cluster.
3. **pages**: depends on `dev-install` having installed with `--pages`. Checks the `gitlab-pages` `Deployment` has ready replicas and `pages.<domain>/` is reachable (any HTTP response, even 404, proves it's not connection-refused).
4. **duckdns**: independent, does NOT attempt real ACME issuance (no real DuckDNS account/domain in CI). Installs the `cert-manager-webhook-duckdns` Helm release with a dummy token and checks its `Deployment` and `APIService` come up healthy. Full DNS-01 issuance against a real DuckDNS account can only be verified manually.
5. **up-down**: runs `saas gitlab down` (destroys the cluster) followed by `saas gitlab up` (recreates it) on the `dev-install` release, and checks that the `root` password persisted in the state is the SAME before and after (the real proof that the cycle doesn't break credentials against data that's already persisted, see CLAUDE.md, "We have to set the initial root password ourselves") and that the ingress serves traffic again after `up`.
6. **ssh-config**: checks that `saas gitlab ssh-config` prints the right block and that the SSH port exposed on the host accepts connections.
7. **prod-ha** (**opt-in only**, `--only prod-ha`, never part of the default full-suite run: 3x CNPG PostgreSQL + 3x Redis/Sentinel + 4x MinIO + the full `prod` GitLab baseline is too heavy for most laptops/CI runners): installs a SEPARATE release (`saase2eha`) with `--mode prod --tls self-signed --force-self-signed-prod`, checks the CloudNativePG `Cluster` reaches 3 instances, `RedisReplication`/`RedisSentinel` are Ready, the MinIO `StatefulSet` reaches 4 ready replicas, and the ingress serves traffic, then deletes itself.

`registry`/`pages`/`up-down`/`ssh-config` depend on `dev-install` having left the release alive. Either run the full suite, or `--only dev-install --keep` before launching just one of them.

## Prerequisites

- `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst`, `curl` installed.
- Docker running.
- `kind_cluster` (`bash-aliases` repo) reachable: nothing to do if your shell already has it loaded; otherwise pass `KIND_CLUSTER_FUNCTIONS`:
  ```bash
  KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh \
    bash tests/gitlab/e2e/run-tests.sh
  ```
- No kind cluster named `saase2e` already existing from a previous interrupted run (see "Manual cleanup").
- Takes several minutes: creates a real kind cluster, installs MetalLB (via `kind_cluster`), ingress-nginx, cert-manager, our own PostgreSQL/Redis/MinIO, and the full GitLab chart.
- `prod-ha` additionally needs enough CPU/RAM headroom for 3x CNPG PostgreSQL + 3x Redis/Sentinel + 4x MinIO + the full `prod` GitLab baseline (~8 vCPU/16GB). Only run it deliberately, never as part of a quick iteration loop.

## How to run it

```bash
bash tests/gitlab/unit/test-argparse-values.sh

bash tests/gitlab/e2e/run-tests.sh                    # full suite (dev-install, registry, pages, duckdns, up-down, ssh-config)
bash tests/gitlab/e2e/run-tests.sh --only dev-install  # a single phase
bash tests/gitlab/e2e/run-tests.sh --keep              # don't tear down at the end, for inspection
bash tests/gitlab/e2e/run-tests.sh --only prod-ha      # opt-in, heavy: HA datastore only, run deliberately
```

## How to read the results

- A `FAIL` on "the ingress serves /users/sign_in" with an HTTP `000` code usually means `ingress-nginx` never got hostPort 80/443 up on the control-plane node. Check `kubectl -n ingress-nginx get pods` by hand (use `--keep`).
- A `FAIL` on "the ingress serves /users/sign_in again after 'up'" but not in the `dev-install` phase almost always points to `_saas_gitlab_cluster_patch_coredns` (`cluster.sh`) not having been reapplied after recreating the cluster. The CoreDNS patch doesn't survive `down` (it destroys the whole cluster), so `up` has to reapply it; if `up` stops calling it, the domain stops resolving inside the cluster (this also affects real CI jobs, not just this test).
- A `FAIL` on "the root password stays the same across the cycle" is a real, serious regression: it means `ROOT_PASSWORD` stopped being correctly persisted/reused in the state. With that broken, `root` login stops working after any `up` (see CLAUDE.md).

## Manual cleanup

If the script is interrupted before the cleanup `trap` runs:

```bash
saas gitlab delete saase2e --purge-storage -y   # if saas.sh is still loaded in your shell
# or, directly:
kind delete cluster --name saase2e
```

## After changes to `services/gitlab/`

1. `bash -n` on any file touched.
2. If the change only touches flag parsing, `state.sh`, StorageClass/version resolution, or the `ssh-config` snippet generation: `bash tests/gitlab/unit/test-argparse-values.sh` first (instant).
3. If the change touches `install.sh`, `datastore.sh`, `datastore-ha.sh`, `operators.sh`, `tls.sh`, `runner.sh`, `cluster.sh`, `ssh.sh`, or any `values/*.yaml.tpl`: validate first with `helm template` (no real cluster, see CLAUDE.md, "Manual testing" section; layer in `registry.yaml.tpl`/`pages.yaml.tpl`/`datastore-ha.yaml.tpl` too when touching those) and then run the full E2E suite. A change to `datastore-ha.sh`/`datastore-ha.yaml.tpl`/`operators.sh` specifically also needs `--only prod-ha` at least once before signing off, since the default suite never exercises the HA path.
4. If the change affects some subcommand's `--help`, also check by hand that it's still consistent with the real options (the test doesn't verify the help text's content).
