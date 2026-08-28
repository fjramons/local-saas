# Self-Hosted SaaS Toolkit

Bash scripts to install and manage self-hosted SaaS services on Kubernetes. The entry point is the `saas` function, which dispatches to a service (`saas gitlab ...`) and that service to its own subcommands. Right now there's only one service, GitLab, but the layout is designed to add more (`saas postgres ...`, etc.) without touching what's already built.

## Setup

Add this to your shell profile (`~/.bashrc`, `~/.bash_aliases`, etc.) so `saas` is available in every new shell:

```bash
# kind_cluster (sibling repo bash-aliases): only needed for --cluster-mode kind
source /path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh
# this repo
source /path/to/local-saas/saas.sh
```

You need `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst`, `curl` on your `PATH`. `saas gitlab install` reports clearly if any is missing.

```bash
saas --help
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

## Repository layout

```
saas.sh              # public dispatcher `saas SERVICE SUBCOMMAND ...`
lib/common.sh         # shared helpers (logging, prompts, getopt)
services/gitlab/       # everything GitLab-specific
  gitlab.sh             # `_saas_gitlab` dispatcher (subcommands)
  lib/                  # cluster, versions, operators, tls, datastore, datastore-ha, install, runner, token, ssh, state, credentials, doctor
  values/               # dev/prod/datastore-ha/registry/pages .yaml.tpl overlays for the gitlab/gitlab chart
tests/gitlab/
  unit/                  # fast, no real cluster (mock kubectl/helm/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
tools/                  # standalone scripts, not part of 'saas' itself (e.g. extracting a Helm chart's real values.yaml)
```

A future service (e.g. a self-hosted database) is added as `services/<name>/` following the same pattern, without touching `saas.sh` beyond one new line in its `case`.
