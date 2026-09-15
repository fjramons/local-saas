# Self-Hosted SaaS Toolkit

Bash scripts to install and manage self-hosted SaaS services on Kubernetes. The entry point is the `saas` function, which dispatches to a service (`saas gitlab ...`, `saas vault ...`, `saas minio ...`) and that service to its own subcommands. Three services exist today, GitLab, Vault (self-hosted OpenBao), and MinIO (standalone S3-compatible object storage), but the layout is designed to add more (`saas postgres ...`, etc.) without touching what's already built. A fourth subcommand, `saas cluster` (alias `saas k8s`), manages the local `kind` clusters those services run on; see "Cluster management" below.

## Setup

Add this to your shell profile (`~/.bashrc`, `~/.bash_aliases`, etc.) so `saas` is available in every new shell:

```bash
source /path/to/local-saas/saas.sh
```

That's it: this repo is self-contained, including its own `saas cluster` for managing local `kind` clusters (no external dependency). You need `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst`, `curl` on your `PATH`. `saas gitlab install` reports clearly if any is missing.

```bash
saas --help
```

Setting `USE_KIND_CLUSTER_FUNCTION=true` switches `saas gitlab|vault|minio`'s `--cluster-mode kind` back to the legacy `kind_cluster` function instead (maintained separately, in the sibling `bash-aliases` repo), for a transition period; see "Cluster management" below for when that's needed.

## Cluster management (saas cluster)

Manages local Kubernetes clusters with `kind`: multiple simultaneous clusters, `LoadBalancer` Services (MetalLB), persistent storage that works across several nodes (`local-path` or `nfs`), optional ingress-nginx/Gateway API, and selective publishing of specific services on the LAN. Also usable as `saas k8s ...`, a pure alias. `saas gitlab|vault|minio` use this by default for `--cluster-mode kind`; you don't need to run it directly for those, unless you want a cluster to exist before installing anything, or want the lower-level operations (`list`, `status`, `expose`, ...) directly.

```bash
saas cluster create                                    # asks the essentials, sensible defaults
saas cluster create --name demo --workers 2 --yes       # unattended, no prompts
saas cluster list                                       # every kind cluster on this host
saas cluster status demo
saas cluster use demo                                   # switch the active kubectl context
saas cluster delete demo --purge-storage -y
```

Publish a specific `Service` on the LAN (not just the host), without recreating the cluster:

```bash
saas cluster expose add demo --service my-service --host-port 8080
saas cluster expose list demo
saas cluster expose remove demo --host-port 8080
```

`create`'s `--provider kind` flag defaults to `kind` (today's only implemented provider, so it never needs to be passed) and is the reserved extension point for a future remote/non-kind provider; see CLAUDE.md's Design notes for how that's meant to be added later without complicating today's command.

### Contextual help

```bash
saas cluster --help
saas cluster create --help
saas cluster expose --help
```

### Tests

```bash
bash tests/cluster/unit/test-argparse-values.sh          # under 1s, no real cluster
bash tests/cluster/e2e/run-tests.sh                       # real, several disposable kind clusters, several minutes
bash tests/cluster/e2e/run-tests.sh --only expose         # a single phase
```

### Coexisting with the legacy `kind_cluster` function

`saas cluster` (v1.0) is a self-contained, faithful port of `kind_cluster`, a bash function maintained separately in the sibling `bash-aliases` repo that this project used to depend on directly. Both manage the exact same kind of real `kind` cluster, with no separate inventory of their own, so `saas cluster list/status/use/delete` already shows and manages clusters created by either tool, and `saas cluster expose` publications are visible to and manageable by both (deliberately: `expose`'s docker labels use the same namespace as the legacy function's). Setting `USE_KIND_CLUSTER_FUNCTION=true` makes `saas gitlab|vault|minio` fall back to calling the legacy `kind_cluster` function instead of this repo's own `saas cluster`, for a transition period; that still needs `kind_cluster` loaded separately:

```bash
USE_KIND_CLUSTER_FUNCTION=true saas gitlab install   # uses the legacy kind_cluster function
```

## GitLab

Self-hosted GitLab, backed by its official Helm chart, with its own PostgreSQL/Redis/MinIO (the chart no longer bundles them: single instance in `--mode dev`, real HA via CloudNativePG/redis-operator/4-node MinIO in `--mode prod`, see below), TLS via cert-manager, a GitLab Runner registered automatically so CI works out of the box, and optional Container Registry (on by default) and GitLab Pages (opt-in).

### Install on a local kind cluster (most common)

```bash
saas gitlab install
```

With no flags, it asks only what's essential, with sensible defaults: a new kind cluster named `gitlab`, `dev` mode (reduced resources, self-signed TLS, domain `gitlab.gitlab.local`), its own PostgreSQL/Redis/MinIO, GitLab Runner registered automatically. To answer nothing at all:

```bash
saas gitlab install --non-interactive -y
```

To pick a version, name, number of workers, or the kind cluster's storage mode:

```bash
saas gitlab versions                     # which versions are available
saas gitlab install --release demo --version 10.3.1 \
    --kind-workers 2 --storage-mode nfs
```

### Install on an existing cluster (production)

```bash
saas gitlab install --cluster-mode existing --mode prod \
    --tls letsencrypt --challenge http01 \
    --domain gitlab.mycompany.com --email me@mycompany.com
```

`--cluster-mode existing` uses whatever `kubeconfig`/context is already active as-is; it doesn't provision any cluster. `--mode prod` requires `--tls letsencrypt` (use `--force-self-signed-prod` if you really want self-signed in this mode, with a warning), and always deploys HA PostgreSQL/Redis/MinIO (see "High availability (`--mode prod`)" below), which is not an opt-in flag. If the cluster isn't publicly reachable on port 80, use DNS-01 instead of HTTP-01:

```bash
saas gitlab install --cluster-mode existing --mode prod \
    --tls letsencrypt --challenge dns01 --dns-provider cloudflare \
    --dns-token "$CF_API_TOKEN" \
    --domain gitlab.mycompany.com --email me@mycompany.com
```

`--dns-provider cloudflare` is native to cert-manager (needs the domain delegated to Cloudflare). `--dns-provider duckdns` also works, useful when you don't have a domain of your own, just a free `<sub>.duckdns.org` one (get an account token at [duckdns.org](https://www.duckdns.org)):

```bash
saas gitlab install --cluster-mode existing --mode prod \
    --tls letsencrypt --challenge dns01 --dns-provider duckdns \
    --dns-token "$DUCKDNS_TOKEN" \
    --domain myapp.duckdns.org --email me@mycompany.com
```

DuckDNS has no native cert-manager support, so this installs a third-party webhook (`cobexer/cert-manager-webhook-duckdns`), the one deliberate exception in this repo to "cert-manager-native only" DNS-01 providers, made because there's simply no way to support DuckDNS otherwise. Cloudflare and any future provider are expected to stay cert-manager-native.

### Container Registry and GitLab Pages

```bash
saas gitlab install --no-registry            # Container Registry is on by default
saas gitlab install --pages                  # GitLab Pages is off by default
```

Both work in `--mode dev` and `--mode prod`, and share the same TLS certificate as the main domain (`registry.<domain>` / `pages.<domain>` as extra SANs, no wildcard cert needed). Pages defaults to path-based project URLs (`pages.<domain>/group/project/`, not `group.pages.<domain>`) precisely so it keeps working with self-signed/HTTP-01 TLS too, instead of requiring a wildcard certificate, which only DNS-01 challenges can obtain.

An optional `--pages-url-mode subdomain` switches Pages to its native per-namespace URLs (`group.pages.<domain>/project`) instead. It needs a wildcard `*.pages.<domain>` certificate, which is only possible with `--tls self-signed` (signed locally, no external validation involved) or `--tls letsencrypt --challenge dns01` (the only ACME challenge that can prove ownership of a wildcard name). It's a second, standalone certificate/Secret, kept separate from the main one, so the main domain's TLS stays unaffected either way:

```bash
# Local kind cluster, no DNS provider account needed at all: self-signed doesn't need to prove
# domain ownership, and '127.0.0.1.nip.io' resolves any subdomain to the host's own address for
# free, so *.pages.127.0.0.1.nip.io works straight out of the box in a browser.
saas gitlab install --pages --pages-url-mode subdomain --domain 127.0.0.1.nip.io

# Real public domain, trusted certificate:
saas gitlab install --pages --pages-url-mode subdomain --tls letsencrypt --challenge dns01 \
    --dns-provider cloudflare --domain gitlab.mycompany.com --dns-token "$CF_TOKEN" \
    --email me@mycompany.com
```

Switching `--pages-url-mode` on an existing release changes the public URL shape of every already-published Pages site (GitLab doesn't redirect between the two), so it's best decided upfront rather than flipped later.

### High availability (`--mode prod`)

`--mode prod` always deploys PostgreSQL/Redis/MinIO with real HA, not the single-instance stack `--mode dev` uses. This is unconditional, not a flag: PostgreSQL via the [CloudNativePG](https://cloudnative-pg.io/) operator (3 instances, automatic failover), Redis via [OT-CONTAINER-KIT's redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator) (Sentinel-based, 3 nodes), MinIO in its own 4-node distributed mode (no operator needed). `--mode dev` is untouched, still meant to be a disposable, minimal local stack. One known trade-off: Sentinel-port authentication is currently left disabled (a workaround for an open upstream bug in redis-operator), while the actual Redis data connection stays fully password-protected.

### Credentials and URL

```bash
saas gitlab credentials
```

Prints the URL, the `root` user, and its initial password (generated and saved during install, no need to go dig it out by hand, though the command also prints how to do that from the Secret if you prefer). Add `--verify` to actually check the saved password against the live instance (execs into the toolbox pod): useful if `root` already existed from a prior install, since GitLab only applies `initialRootPassword` the very first time it boots with no admin user at all.

```bash
saas gitlab credentials --verify
```

### Personal Access Tokens

```bash
saas gitlab token mint                          # root, scope 'api', 1 day
saas gitlab token mint demo root api,create_runner 7
```

Mints a Personal Access Token via `gitlab-rails runner` in the toolbox pod and prints it to stdout. Never persisted anywhere: run it again to mint a new one.

### Diagnose / repair a broken install

```bash
saas gitlab doctor            # report only, nothing is changed
saas gitlab doctor --fix      # apply repairs
```

Checks for problems a host reboot mid-session (or similar disruption outside this tool's control) can leave behind: pods stuck in `Unknown` phase, the PostgreSQL password no longer matching the persisted data directory (`--mode dev` only), the 4 MinIO-derived Secrets drifting from MinIO's own actual running credentials, and a dead `kind-expose-*` SSH proxy container. `--fix` is required to actually apply any repair; a bare `doctor` call never changes anything.

### CI / GitLab Runner

`saas gitlab install` deploys and registers GitLab Runner automatically (Kubernetes executor), so a normal `.gitlab-ci.yml` pipeline just works as soon as the install finishes. Skip it with `--no-runner`. To check its status or re-register it (e.g. after a problem):

```bash
saas gitlab runner status
saas gitlab runner reregister
```

### Clone/pull/push over SSH without touching the host's port 22

Only applies to `--cluster-mode kind`: GitLab's internal SSH is exposed on a high port of the host (2222 by default, `--ssh-host-port` to change it), without using this machine's real port 22.

```bash
saas gitlab ssh-config --apply   # adds the block to ~/.ssh/config
git clone git@gitlab.gitlab.local:group/project.git
```

### Suspend/resume the kind cluster (avoid burning CPU/RAM)

```bash
saas gitlab down     # destroys the kind cluster; data is preserved on the host
saas gitlab up       # recreates the cluster and reinstalls GitLab with the same data
```

`down` genuinely drops CPU/RAM usage to zero (the cluster disappears entirely). `up` isn't an instant resume: it recreates the cluster and reinstalls GitLab from scratch pointing at the same data, several minutes, not seconds. A VM-based alternative with instant resume was evaluated as a preliminary design but not implemented in this iteration.

### Status / uninstall

```bash
saas gitlab status
saas gitlab delete                     # removes GitLab, its namespace, and (on kind) the cluster
saas gitlab delete --purge-storage -y  # also removes the data; irreversible
```

### Integrating with Vault

If you also run `saas vault` (see below), it can be wired up as a secrets backend for this GitLab release, so External Secrets Operator (ESO) syncs GitLab's PostgreSQL/MinIO/object-storage credentials from Vault instead of (or alongside) the ones GitLab generates natively. All of the actual configuration happens on the Vault side (`saas vault integrate gitlab`); this repo's own role is only to apply, into this GitLab cluster, whatever manifests that command generates:

```bash
saas gitlab integrate vault
```

Safe to run at any point, even before Vault has finished its own side: it applies whichever piece is ready (first a small reviewer `ServiceAccount`, later the `SecretStore`/`ExternalSecret` pair) and tells you what to run next. See `saas vault install --integrate-gitlab --help` and `saas vault integrate gitlab --help` for the full walkthrough.

### External object storage (MinIO)

By default GitLab deploys its own private, single-instance (or 4-node in `--mode prod`) MinIO. `--object-storage external` replaces it with a shared `saas minio` instance instead (see the MinIO section below), useful when several services should share one object store, or when MinIO's own lifecycle (upgrades, credential rotation, HA sizing) should be managed independently of any one GitLab release. PostgreSQL/Redis always stay internal to `saas gitlab` either way; only object storage is ever externalized.

```bash
saas minio integrate gitlab --gitlab-release gitlab   # run in the MinIO cluster's own context
saas gitlab integrate minio                            # applies the datastore Secrets here
saas gitlab install --object-storage external           # (re)install pointing at the shared MinIO
```

Unlike the Vault handshake above, this is a single round trip, not two-phase: handing GitLab a set of static connection Secrets needs no cross-cluster authentication trust the way ESO does, so there's no reviewer manifest to apply back and forth. On a brand new `--cluster-mode kind` install, the kind cluster has to exist before `saas minio integrate gitlab` can create the buckets/Secrets in it, so bootstrap with a normal install first (`--object-storage internal`, the default), then integrate, then reinstall with `--object-storage external` (idempotent, same credential-reuse behavior as any other reinstall). `--cluster-mode existing` has no such ordering constraint, since the cluster/namespace are already reachable from the start.

### External database (PostgreSQL)

By default GitLab deploys its own private PostgreSQL (a single instance in `--mode dev`, a CloudNativePG-managed 3-instance HA `Cluster` in `--mode prod`). `--database external` replaces it with a shared `saas postgres` instance instead (see the PostgreSQL section below), independent of `--object-storage`: any combination of internal/external database and object storage is valid. Redis always stays internal to `saas gitlab` either way; only PostgreSQL is ever externalized by this flag.

```bash
saas postgres integrate gitlab --gitlab-release gitlab   # run in the postgres cluster's own context
saas gitlab integrate postgres                            # applies the datastore Secret here
saas gitlab install --database external                    # (re)install pointing at the shared postgres
```

Same single-round-trip shape as the MinIO integration above (a static connection Secret, no cross-cluster authentication trust needed). `saas postgres integrate gitlab` creates the `gitlabhq_production`/`gitlabhq_production_ci` databases and a `gitlab` role on the shared postgres, generating (and, on a re-run, reusing) its own password; `saas gitlab integrate postgres` applies the resulting Secret plus the connection host/port. Same bootstrap-order constraint as MinIO's own integration on a brand new `--cluster-mode kind` install: bootstrap with a normal install first (`--database internal`, the default), integrate, then reinstall with `--database external`.

### Contextual help

```bash
saas gitlab --help
saas gitlab install --help
saas gitlab down --help
```

### Tests

```bash
bash tests/gitlab/unit/test-argparse-values.sh          # under 1s, no real cluster
bash tests/gitlab/e2e/run-tests.sh                       # real, creates a kind cluster, takes several minutes
bash tests/gitlab/e2e/run-tests.sh --only dev-install     # a single phase
bash tests/gitlab/e2e/run-tests.sh --keep                 # don't tear down at the end, for inspection
bash tests/gitlab/e2e/run-tests.sh --only prod-ha          # opt-in, heavy (HA datastore), not part of the default run
```

The default E2E run covers, in order: `dev-install` (a real install, checks the ingress actually serves traffic, `credentials --verify` and `token mint` both work against the live instance, and the runner registers), `registry-push-pull`/`reinstall` (a real image push/pull, then a second `install` against the already-provisioned release), `doctor` (deliberately corrupts a MinIO Secret and checks `doctor`/`doctor --fix` detect and repair it), `registry`/`pages` (their endpoints are genuinely reachable, not just that the chart install succeeded), `duckdns` (the cert-manager webhook installs and comes up healthy; no real ACME issuance, since that needs a real DuckDNS account), `up-down` (destroy/recreate preserves the same credentials against the same data), and `ssh-config`. `prod-ha` is opt-in only (see above) and covers the HA PostgreSQL/Redis/MinIO path.

## Vault

Self-hosted [OpenBao](https://openbao.org/) (a Vault-compatible secrets manager) backed by its official Helm chart, with cert-manager + [Stakater Reloader](https://github.com/stakater/Reloader) as cluster prerequisites, its own internal PKI chain for the Raft/API listener, and fully automated `bao operator init`/unseal: no manual steps, no root token/unseal keys to copy-paste by hand. Also usable as `saas openbao ...`, a pure alias with no behavioral difference whatsoever.

### Install on a local kind cluster (most common)

```bash
saas vault install
```

With no flags: a new kind cluster named `vault`, `dev` mode (single-node Raft, self-signed TLS, domain `vault.vault.local`), 5 Shamir key shares with a threshold of 3. To answer nothing at all:

```bash
saas vault install --non-interactive -y
```

### Install on an existing cluster, or in HA mode

```bash
saas vault versions                          # which chart versions are available
saas vault install --mode prod \
    --cluster-mode existing --storage-class gp3 \
    --tls letsencrypt --challenge http01 \
    --domain vault.mycompany.com --email me@mycompany.com
```

`--mode prod` deploys a genuine 3-replica HA Raft cluster (each node joins the other two over mTLS on its own internal, cert-manager-issued certificate), not an opt-in flag. `--tls`/`--challenge`/`--dns-provider`/`--email` control only the EXTERNAL/ingress certificate (re-encrypted to Vault's own internal-CA backend); `--dns-provider` only supports `cloudflare` here (cert-manager-native), deliberately narrower than `saas gitlab`'s DuckDNS webhook option.

### Credentials: hidden by default

```bash
saas vault credentials                        # URL and seal/init status only
saas vault credentials --reveal-root-token     # break-glass access to everything
saas vault credentials --reveal-unseal-keys
```

Unlike `saas gitlab credentials`, the bare command never prints secret material: the root token and Shamir unseal keys are access to the *entire* secrets store, not one app's login, so they need an explicit flag. Both come from a local file only (`~/.local/state/saas/vault/<release>.keys.env`, `chmod 600`); the root token is never stored in the cluster at all.

### Suspend/resume the kind cluster

```bash
saas vault down     # destroys the kind cluster
saas vault up       # recreates the cluster and reinstalls
```

Whether the underlying Raft data survives depends on the cluster's storage: with kind's default local-path storage it typically does **not** (verified in practice: each fresh PVC binds to a fresh, empty host directory, not the old one, since kind's local-path-provisioner names directories after a random PV UID). Either way, `up` always ends with Vault initialized and unsealed again with zero manual input; if the old data didn't survive, that necessarily means a fresh root token/unseal keys too (the old ones can never unseal a store they didn't create), which `saas vault credentials --reveal-root-token` reports same as any first install.

### Diagnose / repair a broken install

```bash
saas vault doctor            # report only
saas vault doctor --fix      # apply repairs
saas vault unseal            # manual escape hatch: re-apply saved keys to a sealed instance
```

### Integrating with GitLab, MinIO, or External Secrets Operator

`saas vault` can be wired up so [External Secrets Operator](https://external-secrets.io/) (ESO), running in this cluster or any other, syncs secrets from it. ESO itself is never installed by this tool - only the Vault-side configuration and the manifests ESO needs are generated.

**With a `saas gitlab` instance** (its own cluster, possibly a completely different one): the handshake is deliberately two-sided, since each side only ever mutates its own cluster:

```bash
# already have a GitLab instance? wire it up at install time (best-effort, never fails the install):
saas vault install --integrate-gitlab gitlab

# or standalone, at any point:
saas vault integrate gitlab --gitlab-release gitlab
```

The first run typically stops asking you to apply a small reviewer manifest in the GitLab cluster:

```bash
saas gitlab integrate vault   # run in the gitlab cluster's own context
saas vault integrate gitlab --gitlab-release gitlab   # re-run to finish Vault's side
saas gitlab integrate vault   # applies the final SecretStore/ExternalSecret pair
```

Order-independent by design: running any of this before `saas gitlab` even exists yet fails cleanly with an actionable message and never leaves Vault's own configuration touched.

**With a `saas minio` instance**, same two-sided shape as GitLab above, except it's a genuinely useful rotation path, not just a wiring demo: once synced, a credential change made in Vault reaches MinIO's own root-credentials Secret for real (see the MinIO section below):

```bash
saas vault integrate minio --minio-release minio
saas minio integrate vault   # run in the MinIO cluster's own context
saas vault integrate minio --minio-release minio   # re-run to finish Vault's side
saas minio integrate vault   # applies the final SecretStore/ExternalSecret pair
```

**With any other External Secrets Operator installation**, generically (no gitlab-shaped assumptions, seeds one placeholder key purely to prove the wiring works):

```bash
saas vault integrate eso --target-context kind-my-other-cluster
```

### Contextual help

```bash
saas vault --help
saas vault install --help
saas vault integrate gitlab --help
```

### Tests

```bash
bash tests/vault/unit/test-argparse-values.sh                              # under 1s, no real cluster
bash tests/vault/e2e/run-tests.sh                                          # real, creates a kind cluster, takes several minutes
bash tests/vault/e2e/run-tests.sh --only dev-install                        # a single phase
bash tests/vault/e2e/run-tests.sh --keep                                    # don't tear down at the end, for inspection
bash tests/vault/e2e/run-tests.sh --only prod-ha                             # opt-in, heavy (3-replica HA Raft)
bash tests/vault/e2e/run-tests.sh --only dev-install,integrate-gitlab-full,eso-round-trip # opt-in, heavy: full combo
```

The default E2E run covers: `dev-install` (a real install, confirms fully-automated init/unseal, the ingress genuinely serves the API, and the root token authenticates), `doctor` (deliberately reseals the instance and confirms detection/repair), `credentials-defaults` (the bare command never leaks secret material), `up-down` (ends up initialized/unsealed again regardless of whether the underlying data survived), and `integrate-gitlab-order-independence` (running the GitLab integration before any GitLab cluster exists fails cleanly and touches nothing on Vault). `prod-ha`/`integrate-gitlab-full`/`eso-round-trip` are opt-in only, each standing up a second real service.

## MinIO

Standalone, S3-compatible [MinIO](https://min.io/) object storage, deployed with plain manifests (no chart, no operator: single instance in `--mode dev`, a 4-node distributed cluster in `--mode prod`, MinIO clusters itself), TLS via cert-manager, and an Ingress exposing both the web console and the S3 API. Also usable as `saas object-storage ...`, a pure alias with no behavioral difference whatsoever. Unlike GitLab's own private MinIO (still the default there), this is meant to be used standalone, shared across several services, or with its credentials managed through Vault.

### Install on a local kind cluster (most common)

```bash
saas minio install
```

With no flags: a new kind cluster named `minio`, `dev` mode (single instance, self-signed TLS, console at `minio.minio.local`, S3 API at `s3.minio.local`), no buckets pre-created. To answer nothing at all:

```bash
saas minio install --non-interactive -y
```

To pre-create buckets at install time:

```bash
saas minio install --release demo --bucket photos --bucket backups
```

### Install on an existing cluster, or in HA mode

```bash
saas minio install --mode prod \
    --cluster-mode existing --storage-class gp3 \
    --tls letsencrypt --challenge http01 \
    --domain minio.mycompany.com --email me@mycompany.com
```

`--mode prod` deploys a genuine 4-node distributed cluster (MinIO's own erasure-coded clustering, no operator needed), not an opt-in flag. `--dns-provider` only supports `cloudflare` here (cert-manager-native), same deliberately-narrower-than-GitLab choice `saas vault` already makes.

### Buckets

```bash
saas minio bucket create my-bucket
saas minio bucket list
saas minio bucket rm my-bucket --force
```

Runs the pinned MinIO client (`mc`) as a throwaway pod inside the cluster, never on the host, so it never collides with a host-installed `mc` (Midnight Commander, on many systems). If you install a MinIO client on your OWN machine to talk to the exposed S3 endpoint directly, install/alias it as `mcli`, not `mc`, for the same reason: several distros (Debian included) already ship it under that name specifically to avoid the Midnight Commander clash (see [minio/mc's own `CONFLICT.md`](https://github.com/minio/mc/blob/master/CONFLICT.md)).

### Credentials

```bash
saas minio credentials
saas minio credentials --verify   # also checks the saved credentials authenticate live
```

Prints the console URL, the S3 API URL (external and in-cluster), and the root user/password, in plain (like `saas gitlab credentials`, not gated behind a reveal flag the way `saas vault credentials` is: a MinIO root password is one app's login, not access to an entire secrets store).

### Diagnose / repair a broken install

```bash
saas minio doctor            # report only, nothing is changed
saas minio doctor --fix      # apply repairs
```

Checks for pods stuck in `Unknown` phase and the `<release>-credentials` Secret drifting from MinIO's own actual running root password (same kind of drift a host reboot can leave behind). `--fix` is required to actually apply any repair.

### Suspend/resume the kind cluster

```bash
saas minio down     # destroys the kind cluster; data is preserved on the host
saas minio up       # recreates the cluster and reinstalls, buckets re-created idempotently
```

### Status / uninstall

```bash
saas minio status
saas minio delete                     # removes MinIO, its namespace, and (on kind) the cluster
saas minio delete --purge-storage -y  # also removes the data; irreversible
```

### Integrating with Vault

`saas vault` can manage and rotate this release's root credentials (see the Vault section above for the full two-sided walkthrough):

```bash
saas vault integrate minio --minio-release minio
saas minio integrate vault
```

### Integrating with GitLab

Lets a `saas gitlab` install use this MinIO instead of deploying its own private one (see "External object storage (MinIO)" in the GitLab section above for the full walkthrough):

```bash
saas minio integrate gitlab --gitlab-release gitlab
saas gitlab integrate minio
saas gitlab install --object-storage external
```

Creates GitLab's expected bucket set here and hands GitLab a set of static connection Secrets: a single round trip, no reviewer-ServiceAccount handshake needed (unlike the Vault integration, which needs one to establish cross-cluster authentication trust for ESO). If MinIO and GitLab share the same cluster (different namespaces, the realistic single-machine setup), GitLab connects over MinIO's internal Service address, plain HTTP; across genuinely separate clusters, it uses MinIO's external HTTPS endpoint instead, a less-tested path (no CA-trust injection for a self-signed certificate is implemented yet, so prefer `--tls letsencrypt` on `saas minio install` for that case).

### Contextual help

```bash
saas minio --help
saas minio install --help
saas minio bucket --help
```

### Tests

```bash
bash tests/minio/unit/test-argparse-values.sh                              # under 1s, no real cluster
bash tests/minio/e2e/run-tests.sh                                          # real, creates a kind cluster, takes several minutes
bash tests/minio/e2e/run-tests.sh --only dev-install                        # a single phase
bash tests/minio/e2e/run-tests.sh --keep                                    # don't tear down at the end, for inspection
bash tests/minio/e2e/run-tests.sh --only prod-ha                             # opt-in, heavy (4-node distributed)
bash tests/minio/e2e/run-tests.sh --only dev-install,integrate-vault-full   # opt-in, heavy
bash tests/minio/e2e/run-tests.sh --only dev-install,integrate-gitlab-full  # opt-in, heavy
```

The default E2E run covers: `dev-install` (a real install, a real bucket create/list/rm round trip, `credentials --verify` against the live instance), `doctor` (deliberately drifts the root-credentials Secret and confirms detection/repair), and `up-down` (buckets/credentials survive or are idempotently recreated). `prod-ha`/`integrate-vault-full`/`integrate-gitlab-full` are opt-in only, each standing up a second real service (or, for `prod-ha`, a second MinIO release).

## PostgreSQL

Standalone PostgreSQL, deployed with plain manifests in `--mode dev` (single instance, no chart) and via the [CloudNativePG](https://cloudnative-pg.io/) operator in `--mode prod` (real 3-instance HA, the same operator `saas gitlab --mode prod` already uses for its own HA PostgreSQL). Also usable as `saas postgresql ...`, a pure alias with no behavioral difference whatsoever. Unlike GitLab's own private PostgreSQL (still the default there, and deliberately left plaintext, since it's never meant to be reached the way a shared instance is), this service enforces TLS on every connection in both modes: a plaintext connection attempt is rejected outright, not just discouraged.

### Install on a local kind cluster (most common)

```bash
saas postgres install
```

With no flags: a new kind cluster named `postgres`, `dev` mode (single instance, self-signed TLS, admin role `admin`), no databases pre-created. To answer nothing at all:

```bash
saas postgres install --non-interactive -y
```

To pre-create databases at install time:

```bash
saas postgres install --release demo --database photos --database backups
```

The default admin role is `admin`, not `postgres`: CloudNativePG (`--mode prod`) reserves the name `postgres` for its own internal superuser, whose password this tool deliberately never manages, so `admin` is the one name that works identically and correctly as an ordinary role in both modes.

### Install on an existing cluster, or in HA mode

```bash
saas postgres install --mode prod \
    --cluster-mode existing --storage-class gp3 \
    --tls letsencrypt --challenge http01 \
    --domain postgres.mycompany.com --email me@mycompany.com
```

`--mode prod` deploys a genuine 3-instance CloudNativePG-managed `Cluster` (real automatic failover), not an opt-in flag. `--dns-provider` only supports `cloudflare` here (cert-manager-native), same deliberately-narrower-than-GitLab choice `saas vault`/`saas minio` already make.

### Databases

```bash
saas postgres database create my-app
saas postgres database create gitlabhq_production --owner gitlab
saas postgres database list
saas postgres database drop my-app -y
```

With no `--owner`, a new database is simply owned by the release's own admin role. `--owner NAME` creates (idempotently, reusing an already-persisted password on a re-run) a dedicated role plus a companion `<release>-<owner>-credentials` Secret (same `kubernetes.io/basic-auth` shape as `<release>-credentials`), for callers that want isolation: exactly the shape `saas postgres integrate gitlab` itself uses for GitLab's own `gitlab` role.

### Connecting from the host

```bash
saas postgres install --expose --host-port 15432
psql "host=127.0.0.1 port=15432 sslmode=require"
```

Off by default: this service's primary consumers are other SaaS services running inside the cluster (most notably `saas gitlab`), not a host client. `--expose` (kind-mode only) publishes the Service on a host port via the same socat-proxy mechanism `saas gitlab`'s own SSH exposure uses, backed by a real `LoadBalancer` Service (MetalLB-assigned, installed by `saas cluster create` by default) so the proxy container can actually reach it, since a plain `ClusterIP` isn't reachable that way. Not yet supported together with `--mode prod` (CloudNativePG manages its own Services; this tool doesn't wire a `LoadBalancer` override for them in this version).

### Credentials

```bash
saas postgres credentials
saas postgres credentials --verify   # also checks the saved credentials authenticate live
```

Prints the in-cluster connection string, the external host:port (if `--expose` was used), and the admin username/password, in plain (like `saas gitlab credentials`/`saas minio credentials`, not gated behind a reveal flag the way `saas vault credentials` is).

### Diagnose / repair a broken install

```bash
saas postgres doctor            # report only, nothing is changed
saas postgres doctor --fix      # apply repairs
```

Checks for pods stuck in `Unknown` phase and the admin password drifting from the live database (`--mode dev` only; `--mode prod`'s CloudNativePG-managed `Cluster` reconciles its own credentials continuously and isn't covered). `--fix` is required to actually apply any repair. This is also the command to run after a Vault-driven credential rotation (see "Integrating with Vault" below): unlike MinIO, a PostgreSQL role's real password is a database-level fact, not something a pod restart alone changes.

### Suspend/resume the kind cluster

```bash
saas postgres down     # destroys the kind cluster; data is preserved on the host
saas postgres up       # recreates the cluster and reinstalls, pre-created databases re-created idempotently
```

### Status / uninstall

```bash
saas postgres status
saas postgres delete                     # removes postgres, its namespace, and (on kind) the cluster
saas postgres delete --purge-storage -y  # also removes the data; irreversible
```

### Integrating with Vault

`saas vault` can manage and rotate this release's admin credentials (see the Vault section above for the full two-sided walkthrough):

```bash
saas vault integrate postgres --postgres-release postgres
saas postgres integrate vault
```

### Integrating with GitLab

Lets a `saas gitlab` install use this postgres instead of deploying its own private one (see "External database (PostgreSQL)" in the GitLab section above for the full walkthrough):

```bash
saas postgres integrate gitlab --gitlab-release gitlab
saas gitlab integrate postgres
saas gitlab install --database external
```

Creates GitLab's expected `gitlabhq_production`/`gitlabhq_production_ci` databases and a `gitlab` role here, and hands GitLab a static connection Secret plus the host/port: a single round trip, no reviewer-ServiceAccount handshake needed (unlike the Vault integration, which needs one to establish cross-cluster authentication trust for ESO). If postgres and GitLab share the same cluster (different namespaces, the realistic single-machine setup), GitLab connects over postgres's internal Service address; across genuinely separate clusters, this postgres release must have been installed with `--expose` first, a less-tested path.

A full, runnable example from scratch:

```bash
saas postgres install --release pg --mode dev --tls self-signed --non-interactive -y
saas postgres database create myapp --release pg
saas postgres integrate gitlab --postgres-release pg --gitlab-release gitlab
saas gitlab integrate postgres --release gitlab --postgres-release pg
saas gitlab install --release gitlab --database external --non-interactive -y
```

### Contextual help

```bash
saas postgres --help
saas postgres install --help
saas postgres database --help
```

### Tests

```bash
bash tests/postgres/unit/test-argparse-values.sh                              # under 1s, no real cluster
bash tests/postgres/e2e/run-tests.sh                                         # real, creates a kind cluster, takes several minutes
bash tests/postgres/e2e/run-tests.sh --only dev-install                       # a single phase
bash tests/postgres/e2e/run-tests.sh --keep                                   # don't tear down at the end, for inspection
bash tests/postgres/e2e/run-tests.sh --only prod-ha                            # opt-in, heavy (CloudNativePG 3-instance HA)
bash tests/postgres/e2e/run-tests.sh --only dev-install,integrate-vault-full   # opt-in, heavy
bash tests/postgres/e2e/run-tests.sh --only dev-install,integrate-gitlab-full  # opt-in, heavy
```

The default E2E run covers: `dev-install` (a real install; critically, that a plaintext connection is REJECTED while a real TLS connection with the correct password succeeds, proving TLS enforcement actually works; `credentials --verify` against the live instance), `doctor` (deliberately drifts the admin password on the live database and confirms detection/repair), `database` (create/list/drop, including `--owner`), and `up-down` (databases/credentials/TLS enforcement survive or are idempotently recreated). `prod-ha`/`integrate-vault-full`/`integrate-gitlab-full` are opt-in only, each standing up a second real service (or, for `prod-ha`, a second postgres release).

## Repository layout

```
saas.sh              # public dispatcher `saas SERVICE SUBCOMMAND ...`
lib/common.sh         # shared helpers (logging, prompts, getopt, cluster backend selection
                       # (_saas_cluster_backend_*, USE_KIND_CLUSTER_FUNCTION), cert-manager
                       # ensure, StorageClass resolution - shared by every service)
services/cluster/      # 'saas cluster' (alias 'saas k8s'): local kind cluster management,
                       # a self-contained v1.0 port of the legacy kind_cluster function
  cluster.sh            # `_saas_cluster` dispatcher (subcommands)
  lib/                  # create, delete, list, status, use, loadbalancer, kubeconfig, expose,
                         # metallb, ingress, storage, render, network, target, validators, deps
services/gitlab/       # everything GitLab-specific
  gitlab.sh             # `_saas_gitlab` dispatcher (subcommands)
  lib/                  # cluster, versions, operators, tls, datastore, datastore-ha, install,
                         # runner, token, ssh, state, credentials, doctor, vault_integration,
                         # minio_integration, postgres_integration
  values/               # dev/prod/datastore-ha/registry/pages/database-external .yaml.tpl overlays
                         # for the gitlab/gitlab chart
services/vault/        # everything Vault-specific (alias: 'saas openbao')
  vault.sh              # `_saas_vault` dispatcher (subcommands)
  lib/                  # state, secrets, cluster, versions, operators, tls, init, install,
                         # credentials, doctor, integration_common, gitlab_integration,
                         # eso_integration, minio_integration, postgres_integration
  values/               # dev/prod/unseal .yaml.tpl overlays for the openbao/openbao chart, plus
                         # standalone gitlab-*/eso-*/minio-*/postgres-*.yaml.tpl integration manifests
services/minio/        # everything MinIO-specific (alias: 'saas object-storage')
  minio.sh              # `_saas_minio` dispatcher (subcommands)
  lib/                  # state, cluster, backend, tls, install, credentials, doctor, bucket,
                         # integration_common, vault_integration, gitlab_integration
  values/               # standalone gitlab-datastore-secrets.yaml.tpl integration manifest
services/postgres/     # everything PostgreSQL-specific (alias: 'saas postgresql')
  postgres.sh           # `_saas_postgres` dispatcher (subcommands)
  lib/                  # state, cluster, expose, tls, backend, install, credentials, doctor,
                         # database, integration_common, vault_integration, gitlab_integration
  values/               # standalone gitlab-datastore-psql-secret.yaml.tpl integration manifest
tests/cluster/
  unit/                  # fast, no real cluster (mock kind/docker/kubectl)
  e2e/                    # real, spin up several disposable kind clusters
tests/gitlab/
  unit/                  # fast, no real cluster (mock kubectl/helm/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
tests/vault/
  unit/                  # fast, no real cluster (mock kubectl/helm/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
tests/minio/
  unit/                  # fast, no real cluster (mock kubectl/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
tests/postgres/
  unit/                  # fast, no real cluster (mock kubectl/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
tools/                  # standalone scripts, not part of 'saas' itself (e.g. extracting a Helm chart's real values.yaml)
```

A future service is added as `services/<name>/` following the same pattern, without touching `saas.sh` beyond one new line in its `case`.
