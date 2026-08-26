# CLAUDE.md: local-saas

Technical guide for working in this repo. README.md is the usage-oriented entry point; this file documents non-obvious design decisions, verified in practice, so they don't get rediscovered.

## Purpose

| File/folder | Content |
|---|---|
| `saas.sh` | Public dispatcher `saas SERVICE SUBCOMMAND ...` (level 1) |
| `lib/common.sh` | Logging, prompts (`_saas_prompt*`), `_saas_confirm`, `_saas_check_deps`; shared by every service |
| `services/gitlab/gitlab.sh` | `_saas_gitlab` dispatcher (level 2, GitLab subcommands) |
| `services/gitlab/lib/state.sh` | `saas gitlab`'s own state persistence (exception to `kind_cluster`'s convention, see below) |
| `services/gitlab/lib/cluster.sh` | Wraps `kind_cluster` and `StorageClass` resolution in `--cluster-mode existing` |
| `services/gitlab/lib/versions.sh` | Live query of the `gitlab/gitlab` Helm repo |
| `services/gitlab/lib/operators.sh` | Cluster-wide, one-time installs of third-party operators/webhooks (CloudNativePG, redis-operator, the DuckDNS cert-manager webhook) |
| `services/gitlab/lib/datastore.sh` | `--mode dev`: our own single-instance PostgreSQL/Redis/MinIO (plain manifests). Also the shared secrets helper and the 4-node MinIO HA StatefulSet (used by both modes) |
| `services/gitlab/lib/datastore-ha.sh` | `--mode prod` only: HA PostgreSQL (CloudNativePG `Cluster`) and HA Redis (`RedisReplication`/`RedisSentinel`) orchestration |
| `services/gitlab/lib/tls.sh` | cert-manager, `ClusterIssuer`/`Certificate` |
| `services/gitlab/lib/install.sh` | `install`/`up`/`down`/`delete`/`status`: full orchestration |
| `services/gitlab/lib/runner.sh` | GitLab Runner: registration (`glrt-…` token) plus Helm chart |
| `services/gitlab/lib/ssh.sh` | SSH exposure via `kind_cluster expose` plus `~/.ssh/config` snippet |
| `services/gitlab/lib/credentials.sh` | URL and credentials |
| `services/gitlab/values/dev.yaml.tpl` / `prod.yaml.tpl` | Base overlays for the `gitlab/gitlab` chart, rendered with `envsubst` |
| `services/gitlab/values/datastore-ha.yaml.tpl` | Layered on top of `prod.yaml.tpl` unconditionally (HA is not opt-in); points `global.psql`/`global.redis` at the HA datastore |
| `services/gitlab/values/registry.yaml.tpl` / `pages.yaml.tpl` | Layered on when `--registry`/`--pages` are enabled |
| `tests/gitlab/unit/` | Mock `kubectl`/`helm`/`kind_cluster`, no real cluster |
| `tests/gitlab/e2e/` | Real kind cluster, real install |
| `tools/helm-chart-extract-values.sh` | Standalone script, not part of `saas`. Dumps a chart's (and every subchart's) real `values.yaml` straight from its tarball, for verifying chart internals before wiring an overlay to them |
| `.claude/skills/vet-helm-dependency/` | Checklist skill for vetting a candidate third-party Helm chart/operator before adopting it |

## Deployment

```bash
source /path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh   # only if using --cluster-mode kind
source /path/to/local-saas/saas.sh
```

All internal paths are resolved via `BASH_SOURCE` (see `saas.sh` and `services/gitlab/gitlab.sh`), never hardcoded. `kind_cluster` is referenced only by function name (`command -v kind_cluster`), never by any PC's absolute path.

## Writing style

**Language: English.** All code comments, log/prompt/error messages, `--help` text, and README.md content must be in English. This is a standing user preference, not scoped to any one file. This file (`CLAUDE.md`) is written in English too, though it's exempt from the rule below (see next paragraph): write it in whatever form is most useful for Claude to consume in future sessions.

**No artificial line wrapping** in `README.md` and in comments inside this repo's Bash code and YAML manifests: one line of text should be one whole paragraph, not cut at an arbitrary fixed width. Only break a line when the content itself justifies it for readability, such as enumerations, numbered steps, lists, or tables, never as a width convention. This specific rule does NOT apply to `CLAUDE.md` files (this one, or the one at the root of `SaaS local/`): their content is written in whatever format is most optimal for Claude's own consumption, not necessarily unwrapped.

**No em dashes.** Never use `—` as a punctuation mark in anything contributed to this repo (code comments, docs, YAML). If a sentence would reach for one, rephrase it instead: split it into two sentences, use a comma or colon, or restructure the clause. Do not substitute a plain hyphen either, since that reads as a typo. A standing user preference, not scoped to this repo alone (see `SaaS local/CLAUDE.md`, outside this repo, for the general rule).

## Design notes: findings verified in practice

- **The `gitlab/gitlab` chart no longer bundles PostgreSQL/Redis/MinIO** (confirmed live with `helm show values gitlab/gitlab` against version 10.3.x / GitLab 19.3.x: there's no top-level `postgresql:`, `redis:`, or `minio:` key at all, only "External PostgreSQL... External Redis" comments in the header). That's why this repo deploys its own PostgreSQL/Redis/MinIO. The two modes now diverge in how: `--mode dev` keeps the original single-instance plain manifests (`datastore.sh`, no third-party chart, no HA; deliberate, since a disposable local cluster gains nothing real from HA), while `--mode prod` deploys genuine HA **unconditionally** (`datastore-ha.sh`): PostgreSQL via the [CloudNativePG](https://cloudnative-pg.io/) operator (3 instances, real automatic failover), Redis via [OT-CONTAINER-KIT/redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator) (Sentinel-based, 3 nodes), MinIO in its own 4-node distributed mode (`datastore.sh`'s `_saas_gitlab_datastore_minio_ha_apply`; MinIO clusters itself via a multi-host server argument, no operator needed).
  - Bitnami's charts were considered and explicitly ruled out for this: since August 2025 Bitnami's free tier only ships `:latest` (no version pinning) for a reduced image set, and the full versioned catalog moved behind a paid subscription, incompatible with this repo's hard requirement to pin exact third-party versions (see "Pinned versions" below). `spotahome/redis-operator` (a cleaner API than OT-CONTAINER-KIT's) was also considered and ruled out: archived upstream since June 2026, no security/compatibility fixes going forward.
  - **Known trade-off, deliberate**: the `RedisSentinel` CR is created WITHOUT its own `kubernetesConfig.redisSecret`, leaving the Sentinel port (26379) unauthenticated, while the actual Redis data connection (`RedisReplication`'s `redisSecret` plus `redisSentinelConfig.redisReplicationPassword`) stays fully password-protected: `global.redis.sentinelAuth.enabled: false` in `values/datastore-ha.yaml.tpl`. This routes around a currently-open upstream bug (`OT-CONTAINER-KIT/redis-operator` issue #1871: authentication on the embedded-sentinel path). Sentinel only ever exposes topology/monitoring info, never data, so this was judged an acceptable trade-off rather than blocking the feature on an upstream fix. Revisit once that issue is resolved.
  - **The Sentinel master group name is NOT hardcoded.** An initial research pass assumed redis-operator fixed it to `"mymaster"`; verified live (chart 0.26.1) it's actually a real, settable field (`RedisSentinel.spec.redisSentinelConfig.masterGroupName`) whose own default is `"myMaster"` (mixed case) if left unset. Reproduced live: querying Sentinel for `mymaster` (lowercase) when the group is actually named `myMaster` returns `ERR No such master with that name`, so GitLab's Sentinel-aware Redis client would never find the master. `datastore-ha.sh` now sets `masterGroupName: mymaster` explicitly on the `RedisSentinel` CR so it matches `global.redis.host: mymaster` in the values overlay. Never rely on this operator's implicit default.
  - **`RedisReplication`/`RedisSentinel` do NOT expose a `status.conditions` field** in this chart version (confirmed against the installed CRD's OpenAPI schema: `status` only has `connectionInfo`/`masterNode` for `RedisReplication`, and is entirely untyped for `RedisSentinel`). `kubectl wait --for=condition=Ready` on either resource hangs until timeout no matter how healthy the underlying pods actually are (reproduced live: both StatefulSets were `3/3` ready throughout). `datastore-ha.sh` waits on the underlying StatefulSets instead (`<release>-redis` and `<release>-redis-sentinel`, the latter confirmed from the operator's own service-naming source). Do the same for any future check against these two CRDs; don't assume `condition=Ready` exists just because it does for CNPG's `Cluster` (which genuinely has it). The Sentinel StatefulSet specifically is also NOT created immediately when its CR is applied (observed live, over a minute's delay after the RedisReplication StatefulSet is already rolled out, apparently because the operator waits for the replication side to settle first), so `datastore-ha.sh` polls for its existence before calling `kubectl rollout status` on it (see `_saas_gitlab_wait_for_resource`), since `rollout status` fails immediately with `NotFound` rather than waiting for a resource that doesn't exist yet.
  - `--mode dev`'s Redis deliberately stays password-less (`global.redis.auth.enabled: false`, unchanged). A disposable, ClusterIP-only local cluster gains no real security from a password, and the HA/security hardening above is explicitly scoped to `--mode prod` only.
- **PostgreSQL must be >= 17** for GitLab 19.3.x (with 16, the `db:schema:load` migration explicitly warns "requires PostgreSQL >= 17" and later fails). `datastore.sh` uses `postgres:17-alpine`.
- **The default `max_locks_per_transaction` (64) isn't enough** to load GitLab's full `structure.sql` in a single transaction: it fails with `ERROR: out of shared memory / HINT: increase max_locks_per_transaction` partway through `db:schema:load`. Raised to 256 via `args: ["-c", "max_locks_per_transaction=256", ...]` on the PostgreSQL container.
- **The `toolbox` pod goes into `CrashLoopBackOff` if it isn't given an `.s3cfg`**, even when no backup functionality is ever used: its startup command (`gitlab/charts/gitlab/charts/toolbox/templates/deployment.yaml`) unconditionally runs `cp /etc/gitlab/.s3cfg $HOME/.s3cfg && sleep ...` whenever `backups.objectStorage.backend` is `s3` (its default), without that file being mounted unless `backups.objectStorage.config.secret/.key` is explicitly configured. `datastore.sh` generates an extra secret (`<release>-datastore-s3cfg`, `s3cmd` format) pointing at the same MinIO, and the values overlays reference it under `gitlab.toolbox.backups.objectStorage.config`. Without this, `saas gitlab runner` (which mints the `root` PAT via `kubectl exec` on this pod) doesn't work either.
- **The real KAS toggle is `global.kas.enabled`, NOT `gitlab.kas.enabled`**, verified with `helm template` against the real chart: `gitlab.kas.*` doesn't error (Helm doesn't validate unknown keys by default) but does nothing either, so KAS kept installing anyway until this was fixed. `gitlab-pages`, by contrast, is disabled by default already (`global.pages.enabled: false` out of the box), so it didn't need touching.
- **`global.gatewayApi.configureCertmanager` defaults to `true`**, even when Gateway API isn't used at all. With `installCertmanager: false` but without disabling this too, `helm template`/`install` fails hard demanding `certmanager-issuer.email` (a subchart that should only activate with classic Ingress plus `configureCertmanager`, but the real condition is an `OR` across configureCertmanager, ingress, and gateway). The overlays set `global.gatewayApi.enabled/installEnvoy/configureCertmanager` all three to `false` explicitly (Gateway API isn't used in this project).
- **We have to set the initial `root` password ourselves, never let the chart invent it on its own**: GitLab only sets that password in the database the first time it boots with no admin user at all. If, after `saas gitlab down`/`up` (which destroys the cluster, and with it the `Secret`, but preserves the PostgreSQL data on the host), `shared-secrets` were left to generate a new random `Secret`, that value would no longer match the real hash stored in the persisted database, breaking login after every `up`. That's why `install.sh` generates `ROOT_PASSWORD` once, persists it in the state (same as `PSQL_PASSWORD` and the MinIO credentials), and creates the `Secret <release>-gitlab-initial-root-password` itself BEFORE installing the chart, referenced via `global.initialRootPassword.secret/.key`. The same pattern applies to all three credentials, not just PostgreSQL/MinIO.
- **`kind` doesn't reliably support `docker stop`/`docker start` of its nodes** (open, unresolved issues in kubernetes-sigs/kind: #148, #1867), confirmed by research and not deeply tested here because the chosen approach (`down`/`up` = destroy-while-preserving-data / recreate-and-reinstall) doesn't need it: `kind_cluster delete` without `--purge-storage` always left the data in `KIND_CLUSTER_STORAGE_DIR/<name>/...` (host-side, outside the cluster's lifecycle), so a later `create` with the same name plus a `helm upgrade --install` with the same persisted credentials reconstructs the same state. Cost: several minutes of startup, not an instant resume. An instant-resume alternative (a VM with `multipass suspend`) was evaluated as a preliminary design but not implemented here.
- **Deliberate exception to "no state file of its own"** (`kind_cluster`'s convention): `saas gitlab` does need one (`services/gitlab/lib/state.sh`, `~/.local/state/saas/gitlab/<release>.env`) because the `down`/`up` cycle destroys EVERY Kubernetes object of the release (namespace, Secrets, everything). Without saving the install parameters and the three generated credentials (PostgreSQL, MinIO, root) to disk, `up` couldn't reconstruct a state compatible with the already-persisted data. `kind_cluster` doesn't have this problem because it never destroys anything it later has to reconstruct with the same secrets.
- **`--dns-provider duckdns` is implemented via a third-party webhook**: `cobexer/cert-manager-webhook-duckdns` (OCI chart `oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns`, pinned version in `operators.sh`). This is the ONE deliberate exception in this repo to "cert-manager-native DNS-01 providers only" (`cloudflare` stays native, no webhook); any future provider needing a webhook requires an equally explicit, case-by-case decision, not a precedent from this one. Two earlier candidates were found and rejected first: `nolte/cert-manager-webhook-duckdns` (archived) and its fork `ebrianne/cert-manager-webhook-duckdns` (no release since Dec 2023, its GitHub Pages chart repo returns 404). `cobexer`'s is a continuation of that same lineage, actively maintained (Renovate-bot dependency updates) at the time this was implemented. The webhook's own RBAC scopes its Secret-read permission to exactly ONE fixed secret name (`cert-manager-webhook-duckdns-token` in the `cert-manager` namespace), so it's a single, cluster-wide shared DuckDNS account token, not one per release. The last `install`/`up` using `--dns-provider duckdns` to run updates it for every release in that cluster (documented behavior, not a bug).
- **Container Registry and GitLab Pages are implemented**, both usable in `--mode dev` and `--mode prod`, via optional `--registry`/`--no-registry` (default: **on**) and `--pages`/`--no-pages` (default: **off**) flags. Asymmetric defaults, deliberate: Registry is a baseline expectation with low cost (one more Deployment, its bucket already existed), while Pages carries its own subdomain/TLS-SAN footprint most local/CI-only installs won't need.
  - Container Registry needs its own storage config (confirmed: it does NOT reuse `global.appConfig.object_store`; `registry.storage.secret` is a separate Secret whose `config` key is the registry's native S3-driver YAML, spliced into its `config.yml` at startup by the subchart's own init script). `datastore.sh` always creates this secret (`<release>-datastore-registry-storage`), same precedent as the always-created `.s3cfg`.
  - Both `registry.<domain>` and `pages.<domain>` are added as extra SANs on the SAME certificate as the main domain (`tls.sh`'s `_saas_gitlab_certificate_request`, now variadic). No second certificate, no wildcard.
  - **Pages TLS decision**: `global.pages.namespaceInPath: true` (path-based Pages URLs, `pages.<domain>/group/project/`) instead of the chart's default subdomain-based routing (`project.group.pages.<domain>`), which would require a WILDCARD `*.pages.<domain>` certificate, obtainable only via DNS-01. `namespaceInPath: true` keeps Pages working with self-signed/HTTP-01 TLS too, at the cost of a less conventional Pages URL shape. Documented trade-off, not an oversight.
- **`--storage-mode` (kind) vs. `--storage-class` (existing) are mutually exclusive and validated as an explicit error**, never a flag silently ignored. See `install.sh`, the `--cluster-mode` validation section.
- **No flag requires a value with no default unless it's genuinely impossible to guess**: `--email`/`--domain` (with `--tls letsencrypt`) and `--dns-token` (with `--challenge dns01`) are the only three. Everything else, including `StorageClass` resolution in `--cluster-mode existing` with several ambiguous options, has a reasonable automatic default even in `--non-interactive` (warning on stderr if it had to pick among several), the same principle `kind_cluster` already uses for its prompts.

## Manual testing

```bash
bash -n saas.sh lib/common.sh services/gitlab/gitlab.sh services/gitlab/lib/*.sh
bash tests/gitlab/unit/test-argparse-values.sh
bash tests/gitlab/e2e/run-tests.sh              # real, takes several minutes
bash tests/gitlab/e2e/run-tests.sh --only dev-install
```

Additional validation useful before changing the values overlays, without paying for a real install:

```bash
SAAS_DOMAIN=x SAAS_RELEASE=gitlab SAAS_NAMESPACE=gitlab SAAS_INGRESS_CLASS=nginx SAAS_TLS_SECRET=x \
  envsubst '${SAAS_DOMAIN} ${SAAS_RELEASE} ${SAAS_NAMESPACE} ${SAAS_INGRESS_CLASS} ${SAAS_TLS_SECRET}' \
  < services/gitlab/values/dev.yaml.tpl | helm template gitlab gitlab/gitlab -f - --namespace gitlab >/dev/null
```

Note: `helm template` without a real cluster doesn't detect the real Kubernetes API version (`Capabilities.APIVersions`), so it may render `Ingress` with the old `extensions/v1beta1` schema instead of the real `networking.k8s.io/v1` a `helm install` against a real cluster will use. Not a bug if it only shows up in local `helm template`.

## Dependencies

| Tool | Used by |
|---|---|
| `kubectl`, `helm`, `jq`, `envsubst` | all of `services/gitlab/lib/*.sh` |
| `kind_cluster` (`bash-aliases` repo) | `cluster.sh`, `ssh.sh`; `--cluster-mode kind` only |
| `curl` (inside the cluster, `curlimages/curl` image) | `runner.sh`, to call the GitLab API from inside without exposing anything new on the host |

## Pinned versions

| Image | Tag | Where | Reason |
|---|---|---|---|
| `postgres` | `17-alpine` | `datastore.sh` | GitLab 19.3.x requires PostgreSQL >= 17 (`--mode dev` only) |
| `redis` | `7-alpine` | `datastore.sh` | No strict version requirement; kept reasonably recent (`--mode dev` only) |
| `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | `datastore.sh` | Concrete tag verified against Docker Hub at time of writing; no chart keeps it up to date on its own (both modes: single-instance and 4-node HA) |
| `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | `datastore.sh` | Same as above |
| `curlimages/curl` | `8.11.0` | `runner.sh` | Pinned for consistency, no particular compatibility reason |
| `ghcr.io/cloudnative-pg/postgresql` | `17` | `datastore-ha.sh` | Floating major tag (same minimal-pinning convention as `postgres:17-alpine`). CNPG's own PostgreSQL 17 image, `--mode prod` only |
| `quay.io/opstree/redis` | `v7.2.16` | `datastore-ha.sh` | redis-operator's Redis image, `--mode prod` only |
| `quay.io/opstree/redis-sentinel` | `v7.2.16` | `datastore-ha.sh` | Matching Sentinel image, same version line |
| `cnpg/cloudnative-pg` (Helm chart) | `0.29.0` (operator `1.30.0`) | `operators.sh` | CloudNativePG operator. Verify with `helm search repo cnpg/cloudnative-pg --versions` before bumping |
| `ot-helm/redis-operator` (Helm chart) | `0.26.1` (app `0.26.0`) | `operators.sh` | OT-CONTAINER-KIT redis-operator. `spotahome/redis-operator` was considered and rejected (archived upstream since June 2026); verify with `helm search repo ot-helm/redis-operator --versions` before bumping |
| `oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns` (Helm chart) | `2.0.0` | `operators.sh` | DuckDNS cert-manager webhook. A young project (created April 2026) but the actively-maintained continuation of the nolte to ebrianne to cobexer lineage; verify with `helm show chart oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns --version X` before bumping |

`gitlab/gitlab`, `gitlab/gitlab-runner`, and `jetstack/cert-manager` are always installed "latest stable" via their own Helm repo (`versions.sh`, `tls.sh`), not pinned here. The three Helm charts above (CNPG, redis-operator, DuckDNS webhook) ARE pinned, deliberately: unlike `gitlab/gitlab` (whose values API this repo tracks closely version-to-version anyway), an unpinned third-party operator/webhook could silently change CRD schemas or RBAC between runs. Bitnami's charts were ruled out for anything in this repo needing pinning: since August 2025 its free tier only ships `:latest` (no version pinning), full catalog behind a paid subscription.
