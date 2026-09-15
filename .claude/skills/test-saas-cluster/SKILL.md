---
name: test-saas-cluster
description: Re-runs the saas cluster tests (unit + real E2E) after modifying any file under services/cluster/ or the _saas_cluster_backend_* functions in lib/common.sh. Use whenever create.sh, delete.sh, list.sh, status.sh, use.sh, loadbalancer.sh, kubeconfig.sh, expose.sh, metallb.sh, ingress.sh, storage.sh, render.sh, network.sh, target.sh, validators.sh, deps.sh, or cluster.sh change. A change here also affects saas gitlab/vault/minio (they all use this backend by default), so also skim .claude/skills/test-saas-gitlab, test-saas-vault, test-saas-minio.
---

# Testing `saas cluster`

`services/cluster/` is a self-contained, v1.0 port of the `kind_cluster` bash function (maintained separately, in a sibling repo) into this repo: `saas cluster` (alias `saas k8s`) creates and manages local kind clusters directly, with no external dependency. `saas gitlab|vault|minio` all use it by default through the shared `_saas_cluster_backend_*` functions in `lib/common.sh`; setting `USE_KIND_CLUSTER_FUNCTION=true` falls back to the legacy `kind_cluster` function instead, for a transition period.

This repo has two test tiers for `services/cluster/`:

1. `tests/cluster/unit/test-argparse-values.sh`: fast (<1s), no real cluster, mocks `kind`/`docker`/`kubectl`. Covers validators (including `--provider`), IP arithmetic, `--expose-mode` reserved port-map rendering, and `_saas_cluster_suggest_target`'s fallback logic. Run this first, on every iteration.
2. `tests/cluster/e2e/run-tests.sh`: real, creates several disposable `kind` clusters. Takes several minutes. Run this before signing off on any change to `services/cluster/`'s actual cluster-management logic.

## What the E2E suite checks

Ported 1:1 from the sibling repo's own `tests/kind-cluster/run-tests.sh` (same phases, same assertions, calling `saas cluster` instead of `kind_cluster`):

1. **multi-cluster**: two real clusters created back to back (`local-path`/`nfs` storage, 2 workers each), both show up in `kind get clusters` and as `kind-*` kubectl contexts, and `saas cluster list`/`status`/`use` all work against them.
2. **lb**: `saas cluster deploy-loadbalancer` on both clusters from `multi-cluster`, a real `LoadBalancer` Service on each, checks both get an `EXTERNAL-IP`, that the two IP ranges don't collide (MetalLB's own cross-cluster collision avoidance), and that `curl` against each IP actually reaches the pod.
3. **storage-local-path**: on the `multi-cluster` local-path cluster, cordon the node a StatefulSet pod is on, delete the pod, and confirm it stays `Pending` (the documented, expected `nodeAffinity` limitation, not a bug) until the node is uncordoned, then confirm the SAME data (not a fresh empty volume) comes back.
4. **storage-nfs**: same StatefulSet, on the `multi-cluster` nfs cluster: cordoning + deleting the pod reschedules it onto a DIFFERENT node directly (no `Pending`), with the SAME data. Also asserts `saas cluster delete --purge-storage` for real, including its root-owned-files (privileged NFS server) fallback path.
5. **idempotency**: create -> delete -> create with the same cluster name, confirming `delete` genuinely frees the name/context/network for reuse.
6. **port-map**: a cluster created with `-p 18080:30080`, a real `curl` to `localhost:18080` confirms traffic reaches the pod through the Docker -> node -> Service NodePort mapping, not just that the YAML was generated correctly.
7. **fault-injection**: `helm` is swapped for a script that always fails, only for one `create` call with `--storage-mode nfs`; confirms `create`'s exit code reflects the resulting NFS-setup failure (non-zero) while the cluster itself still exists (post-creation failures warn, they don't roll back the cluster, by design).
8. **ingress**: a cluster created with `--expose-mode ingress-nginx`; a real `curl -H "Host: test.local" http://localhost/` confirms traffic reaches the pod through the Ingress.
9. **gateway-api**: same as `ingress`, but with `--expose-mode gateway-api` (Envoy Gateway) and an `HTTPRoute`.
10. **expose**: `saas cluster expose add` against both a `ClusterIP` Service (the real test of the proxy's route-to-the-Service-CIDR mechanism) and a `LoadBalancer` IP via `--target` (a control case, already reachable with no fix needed); checks `expose list`, that a repeated `add` on the same port fails (idempotency), that `expose remove` actually stops traffic, and that `delete` automatically cleans up any remaining `expose` proxies.

## Prerequisites

- `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst` installed.
- Docker running.
- No kind clusters named `sce2e-*` already existing from a previous interrupted run (see "Manual cleanup").
- Free host ports 18080/18081/18082/80/443 (same ports `saas gitlab|vault|minio`'s own E2E suites use; don't run both at once).
- Takes several minutes: creates several real kind clusters, installs MetalLB, ingress-nginx, Envoy Gateway, and an NFS server across the different phases.
- inotify limits: with several clusters created in the same run, low host inotify limits (`fs.inotify.max_user_instances`/`max_user_watches`, Linux defaults) are a known, documented cause of consistent (not transient) cluster-creation failures; `saas cluster create` warns about this itself (`_saas_cluster_check_inotify`) if they're low.

## How to run it

```bash
bash tests/cluster/unit/test-argparse-values.sh

bash tests/cluster/e2e/run-tests.sh                       # full suite, several minutes
bash tests/cluster/e2e/run-tests.sh --only expose          # a single phase
bash tests/cluster/e2e/run-tests.sh --keep                 # don't tear down at the end, for inspection
```

## How to read the results

- A `FAIL` on "EXTERNAL-IP assigned" usually means MetalLB's controller/speaker never became `Available`, or its IP-pool webhook never accepted the `IPAddressPool`; check `kubectl -n metallb-system get pods` by hand (use `--keep`).
- A `FAIL` on "writer-0 stays Pending after rescheduling" in `storage-local-path` is itself a real regression report only if it FAILS (the assertion is that it DOES stay `Pending`, the documented limitation): if it reschedules successfully instead, the `local-path` nodeAffinity workaround changed behavior unexpectedly.
- A `FAIL` on "curl ... reaches the pod" for `port-map`/`ingress`/`gateway-api`/`expose` after a few retries (15x, 2s apart, already built into the test) usually means the underlying component (ingress-nginx/Envoy Gateway/the expose proxy) never came up cleanly; check `kubectl -n <namespace> get pods` for the relevant one.
- A `FAIL` on the cluster still existing after `fault-injection` would mean `create` started rolling back the whole cluster on a post-creation component failure, a deliberate design change from "warn, don't revert" that needs to be intentional, not accidental.

## Manual cleanup

If the script is interrupted before the cleanup `trap` runs:

```bash
saas cluster delete sce2e-foo --purge-storage -y       # if saas.sh is still loaded in your shell
saas cluster delete sce2e-bar --purge-storage -y
saas cluster delete sce2e-idem --purge-storage -y
saas cluster delete sce2e-portmap --purge-storage -y
saas cluster delete sce2e-fault --purge-storage -y
saas cluster delete sce2e-ingress --purge-storage -y
saas cluster delete sce2e-gateway --purge-storage -y
saas cluster delete sce2e-expose --purge-storage -y
# or, directly, for any of the above:
kind delete cluster --name sce2e-foo
```

## After changes to `services/cluster/`

1. `bash -n` on any file touched.
2. `bash tests/cluster/unit/test-argparse-values.sh` first (instant): validators, IP arithmetic, port-map rendering, `suggest_target`.
3. Run the full E2E suite (`bash tests/cluster/e2e/run-tests.sh`). If the change is scoped to one area, `--only` the relevant phase(s) is faster, but run the full suite at least once before signing off, since several phases share clusters and can mask ordering issues.
4. Since `saas gitlab|vault|minio` all default to this backend, also re-run at least `tests/gitlab/unit/test-argparse-values.sh` (fast) after touching the shared `_saas_cluster_backend_*` functions in `lib/common.sh`, and `tests/gitlab/e2e/run-tests.sh --only dev-install` (or the equivalent for vault/minio) if the change could affect `create`/`delete`/`use`/`expose add`/`expose remove`'s actual argument shape.
5. If the change affects `USE_KIND_CLUSTER_FUNCTION`'s gating logic itself (`_saas_require_cluster_backend`/`_saas_cluster_backend_*` in `lib/common.sh`), also verify the legacy path still works: `USE_KIND_CLUSTER_FUNCTION=true KIND_CLUSTER_FUNCTIONS=/path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh bash tests/gitlab/e2e/run-tests.sh --only dev-install`.
6. If the change affects some subcommand's `--help`, also check by hand that it's still consistent with the real options (the tests don't verify help text content).
