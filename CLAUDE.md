# CLAUDE.md — local-saas

Technical guide for working in this repo. README.md is the usage-oriented entry point; this file documents non-obvious design decisions, verified in practice, so they don't get rediscovered.

## Purpose

| File/folder | Content |
|---|---|
| `saas.sh` | Public dispatcher `saas SERVICE SUBCOMMAND ...` (level 1) |
| `lib/common.sh` | Logging, prompts (`_saas_prompt*`), `_saas_confirm`, `_saas_check_deps` — shared by every service |
| `services/gitlab/gitlab.sh` | `_saas_gitlab` dispatcher (level 2, GitLab subcommands) |
| `services/gitlab/lib/state.sh` | `saas gitlab`'s own state persistence (exception to `kind_cluster`'s convention, see below) |
| `services/gitlab/lib/cluster.sh` | Wraps `kind_cluster` + `StorageClass` resolution in `--cluster-mode existing` |
| `services/gitlab/lib/versions.sh` | Live query of the `gitlab/gitlab` Helm repo |
| `services/gitlab/lib/datastore.sh` | Our own PostgreSQL/Redis/MinIO (plain manifests) |
| `services/gitlab/lib/tls.sh` | cert-manager + `ClusterIssuer`/`Certificate` |
| `services/gitlab/lib/install.sh` | `install`/`up`/`down`/`delete`/`status` — full orchestration |
| `services/gitlab/lib/runner.sh` | GitLab Runner: registration (`glrt-…` token) + Helm chart |
| `services/gitlab/lib/ssh.sh` | SSH exposure via `kind_cluster expose` + `~/.ssh/config` snippet |
| `services/gitlab/lib/credentials.sh` | URL + credentials |
| `services/gitlab/values/*.yaml.tpl` | `dev`/`prod` overlays for the `gitlab/gitlab` chart, rendered with `envsubst` |
| `tests/gitlab/unit/` | Mock `kubectl`/`helm`/`kind_cluster`, no real cluster |
| `tests/gitlab/e2e/` | Real kind cluster, real install |

## Deployment

```bash
source /path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh   # only if using --cluster-mode kind
source /path/to/local-saas/saas.sh
```

All internal paths are resolved via `BASH_SOURCE` (see `saas.sh` and `services/gitlab/gitlab.sh`) — never hardcoded. `kind_cluster` is referenced only by function name (`command -v kind_cluster`), never by any PC's absolute path.

## Writing style

**Language: English.** All code comments, log/prompt/error messages, `--help` text, and README.md content must be in English — this is a standing user preference, not scoped to any one file. This file (`CLAUDE.md`) is written in English too, though it's exempt from the rule below (see next paragraph): write it in whatever form is most useful for Claude to consume in future sessions.

**No artificial line wrapping** in `README.md` and in comments inside this repo's Bash code and YAML manifests: one line of text should be one whole paragraph, not cut at an arbitrary fixed width. Only break a line when the content itself justifies it for readability — enumerations, numbered steps, lists, tables — never as a width convention. This specific rule does NOT apply to `CLAUDE.md` files (this one, or the one at the root of `SaaS local/`): their content is written in whatever format is most optimal for Claude's own consumption, not necessarily unwrapped.

## Design notes — findings verified in practice

- **The `gitlab/gitlab` chart no longer bundles PostgreSQL/Redis/MinIO** (confirmed live with `helm show values gitlab/gitlab` against version 10.3.x / GitLab 19.3.x: there's no top-level `postgresql:`, `redis:`, or `minio:` key at all, only "External PostgreSQL... External Redis" comments in the header). That's why this repo deploys its own single-instance PostgreSQL/Redis/MinIO (`datastore.sh`, plain manifests, no third-party chart) in both `dev` and `prod` mode — **there is no high availability**, a known and deliberate limitation of this first version, not an oversight. Extending this to properly managed PostgreSQL/Redis (operators, replicas) is out of scope for now.
- **PostgreSQL must be >= 17** for GitLab 19.3.x (with 16, the `db:schema:load` migration explicitly warns "requires PostgreSQL >= 17" and later fails) — `datastore.sh` uses `postgres:17-alpine`.
- **The default `max_locks_per_transaction` (64) isn't enough** to load GitLab's full `structure.sql` in a single transaction — it fails with `ERROR: out of shared memory / HINT: increase max_locks_per_transaction` partway through `db:schema:load`. Raised to 256 via `args: ["-c", "max_locks_per_transaction=256", ...]` on the PostgreSQL container.
- **The `toolbox` pod goes into `CrashLoopBackOff` if it isn't given an `.s3cfg`**, even when no backup functionality is ever used: its startup command (`gitlab/charts/gitlab/charts/toolbox/templates/deployment.yaml`) unconditionally runs `cp /etc/gitlab/.s3cfg $HOME/.s3cfg && sleep ...` whenever `backups.objectStorage.backend` is `s3` — its default — without that file being mounted unless `backups.objectStorage.config.secret/.key` is explicitly configured. `datastore.sh` generates an extra secret (`<release>-datastore-s3cfg`, `s3cmd` format) pointing at the same MinIO, and the values overlays reference it under `gitlab.toolbox.backups.objectStorage.config`. Without this, `saas gitlab runner` (which mints the `root` PAT via `kubectl exec` on this pod) doesn't work either.
- **The real KAS toggle is `global.kas.enabled`, NOT `gitlab.kas.enabled`** — verified with `helm template` against the real chart: `gitlab.kas.*` doesn't error (Helm doesn't validate unknown keys by default) but does nothing either, so KAS kept installing anyway until this was fixed. `gitlab-pages`, by contrast, is disabled by default already (`global.pages.enabled: false` out of the box), so it didn't need touching.
- **`global.gatewayApi.configureCertmanager` defaults to `true`**, even when Gateway API isn't used at all — with `installCertmanager: false` but without disabling this too, `helm template`/`install` fails hard demanding `certmanager-issuer.email` (a subchart that should only activate with classic Ingress + `configureCertmanager`, but the real condition is an `OR` across both configureCertmanager, ingress, and gateway). The overlays set `global.gatewayApi.enabled/installEnvoy/configureCertmanager` all three to `false` explicitly (Gateway API isn't used in this project).
- **We have to set the initial `root` password ourselves, never let the chart invent it on its own**: GitLab only sets that password in the database the first time it boots with no admin user at all. If, after `saas gitlab down`/`up` (which destroys the cluster, and with it the `Secret`, but preserves the PostgreSQL data on the host) `shared-secrets` were left to generate a new random `Secret`, that value would no longer match the real hash stored in the persisted database — login broken after every `up`. That's why `install.sh` generates `ROOT_PASSWORD` once, persists it in the state (same as `PSQL_PASSWORD` and the MinIO credentials), and creates the `Secret <release>-gitlab-initial-root-password` itself BEFORE installing the chart, referenced via `global.initialRootPassword.secret/.key` — the same pattern for all three credentials, not just PostgreSQL/MinIO.
- **`kind` doesn't reliably support `docker stop`/`docker start` of its nodes** (open, unresolved issues in kubernetes-sigs/kind: #148, #1867) — confirmed by research, not deeply tested here because the chosen approach (`down`/`up` = destroy-while-preserving-data / recreate-and-reinstall) doesn't need it: `kind_cluster delete` without `--purge-storage` always left the data in `KIND_CLUSTER_STORAGE_DIR/<name>/...` (host-side, outside the cluster's lifecycle), so a later `create` with the same name plus a `helm upgrade --install` with the same persisted credentials reconstructs the same state. Cost: several minutes of startup, not an instant resume. The instant-resume alternative (a VM with `multipass suspend`) is documented as a preliminary design in `Mis notas/` (outside this repo), not implemented.
- **Deliberate exception to "no state file of its own"** (`kind_cluster`'s convention): `saas gitlab` does need one (`services/gitlab/lib/state.sh`, `~/.local/state/saas/gitlab/<release>.env`) because the `down`/`up` cycle destroys EVERY Kubernetes object of the release (namespace, Secrets, everything) — without saving the install parameters and the three generated credentials (PostgreSQL, MinIO, root) to disk, `up` couldn't reconstruct a state compatible with the already-persisted data. `kind_cluster` doesn't have this problem because it never destroys anything it later has to reconstruct with the same secrets.
- **`--dns-provider duckdns` is documented but NOT implemented**: it's the most commonly cited "free domain with no domain of your own needed" option for DNS-01, but it requires a third-party `cert-manager` webhook (DuckDNS has no native `cert-manager` support) whose exact Helm chart/image couldn't be verified with confidence from this environment — better to fail with a clear message than integrate an unverified reference. `cloudflare` is native to `cert-manager` (no webhook) and is the only DNS-01 provider implemented in this version. Extension point: add `_saas_gitlab_certmanager_issuer_letsencrypt_dns01_duckdns` in `tls.sh` once a concrete, maintained webhook is verified.
- **Container Registry and GitLab Pages stay disabled in `--mode prod` too** in this first version (`registry.enabled: false`, `global.pages.enabled: false` which is already the default) — enabling them properly requires solving their own storage backend (Container Registry doesn't automatically reuse `global.appConfig.object_store`) and wasn't part of the original ask (GitLab + working CI). Documented, not implemented.
- **`--storage-mode` (kind) vs. `--storage-class` (existing) are mutually exclusive and validated as an explicit error**, never a flag silently ignored — see `install.sh`, the `--cluster-mode` validation section.
- **No flag requires a value with no default unless it's genuinely impossible to guess**: `--email`/`--domain` (with `--tls letsencrypt`) and `--dns-token` (with `--challenge dns01`) are the only three. Everything else, including `StorageClass` resolution in `--cluster-mode existing` with several ambiguous options, has a reasonable automatic default even in `--non-interactive` (warning on stderr if it had to pick among several) — the same principle `kind_cluster` already uses for its prompts.

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

Note: `helm template` without a real cluster doesn't detect the real Kubernetes API version (`Capabilities.APIVersions`), so it may render `Ingress` with the old `extensions/v1beta1` schema instead of the real `networking.k8s.io/v1` a `helm install` against a real cluster will use — not a bug if it only shows up in local `helm template`.

## Dependencies

| Tool | Used by |
|---|---|
| `kubectl`, `helm`, `jq`, `envsubst` | all of `services/gitlab/lib/*.sh` |
| `kind_cluster` (`bash-aliases` repo) | `cluster.sh`, `ssh.sh` — `--cluster-mode kind` only |
| `curl` (inside the cluster, `curlimages/curl` image) | `runner.sh`, to call the GitLab API from inside without exposing anything new on the host |

## Pinned versions

| Image | Tag | Where | Reason |
|---|---|---|---|
| `postgres` | `17-alpine` | `datastore.sh` | GitLab 19.3.x requires PostgreSQL >= 17 |
| `redis` | `7-alpine` | `datastore.sh` | No strict version requirement; kept reasonably recent |
| `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | `datastore.sh` | Concrete tag verified against Docker Hub at time of writing — no chart keeps it up to date on its own |
| `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | `datastore.sh` | Same as above |
| `curlimages/curl` | `8.11.0` | `runner.sh` | Pinned for consistency, no particular compatibility reason |

`gitlab/gitlab`, `gitlab/gitlab-runner`, and `jetstack/cert-manager` are always installed "latest stable" via their own Helm repo (`versions.sh`, `tls.sh`) — not pinned here.
