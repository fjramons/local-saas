# Self-Hosted SaaS Toolkit

Bash scripts to install and manage self-hosted SaaS services on Kubernetes. The entry point is the `saas` function, which dispatches to a service (`saas gitlab ...`) and that service to its own subcommands. Right now there's only one service — GitLab — but the layout is designed to add more (`saas postgres ...`, etc.) without touching what's already built.

## Setup

Add this to your shell profile (`~/.bashrc`, `~/.bash_aliases`, etc.) so `saas` is available in every new shell:

```bash
# kind_cluster (sibling repo bash-aliases) — only needed for --cluster-mode kind
source /path/to/bash-aliases/.bash_aliases.d/local-cluster-functions.sh
# this repo
source /path/to/local-saas/saas.sh
```

You need `kind`, `docker`, `kubectl`, `helm`, `jq`, `envsubst`, `curl` on your `PATH`. `saas gitlab install` reports clearly if any is missing.

```bash
saas --help
```

## GitLab

Self-hosted GitLab, backed by its official Helm chart, with its own PostgreSQL/Redis/MinIO (single instance — the chart no longer bundles them), TLS via cert-manager, and a GitLab Runner registered automatically so CI works out of the box.

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

`--cluster-mode existing` uses whatever `kubeconfig`/context is already active as-is — it doesn't provision any cluster. `--mode prod` requires `--tls letsencrypt` (use `--force-self-signed-prod` if you really want self-signed in this mode, with a warning). If the cluster isn't publicly reachable on port 80, use DNS-01 instead of HTTP-01:

```bash
saas gitlab install --cluster-mode existing --mode prod \
    --tls letsencrypt --challenge dns01 --dns-provider cloudflare \
    --dns-token "$CF_API_TOKEN" \
    --domain gitlab.mycompany.com --email me@mycompany.com
```

(`--dns-provider cloudflare` is the only DNS-01 provider implemented in this version — it needs the domain delegated to Cloudflare. See `CLAUDE.md` for why and how to add another provider.)

### Credentials and URL

```bash
saas gitlab credentials
```

Prints the URL, the `root` user, and its initial password (generated and saved during install — no need to go dig it out by hand, though the command also prints how to do that from the Secret if you prefer).

### CI / GitLab Runner

`saas gitlab install` deploys and registers GitLab Runner automatically (Kubernetes executor) — a normal `.gitlab-ci.yml` pipeline just works as soon as the install finishes. Skip it with `--no-runner`. To check its status or re-register it (e.g. after a problem):

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
saas gitlab down    # destroys the kind cluster; data is preserved on the host
saas gitlab up       # recreates the cluster and reinstalls GitLab with the same data
```

`down` genuinely drops CPU/RAM usage to zero (the cluster disappears entirely). `up` isn't an instant resume: it recreates the cluster and reinstalls GitLab from scratch pointing at the same data — several minutes, not seconds. See `Mis notas/` (outside this repo) for the preliminary design of a VM-based alternative with instant resume.

### Status / uninstall

```bash
saas gitlab status
saas gitlab delete                     # removes GitLab, its namespace, and (on kind) the cluster
saas gitlab delete --purge-storage -y  # also removes the data — irreversible
```

### Contextual help

```bash
saas gitlab --help
saas gitlab install --help
saas gitlab down --help
```

### Tests

```bash
bash tests/gitlab/unit/test-argparse-values.sh          # <1s, no real cluster
bash tests/gitlab/e2e/run-tests.sh                       # real, creates a kind cluster, takes several minutes
bash tests/gitlab/e2e/run-tests.sh --only dev-install     # a single phase
bash tests/gitlab/e2e/run-tests.sh --keep                 # don't tear down at the end, for inspection
```

See `CLAUDE.md` for what each E2E phase checks and the non-obvious design decisions behind GitLab support.

## Repository layout

```
saas.sh              # public dispatcher `saas SERVICE SUBCOMMAND ...`
lib/common.sh         # shared helpers (logging, prompts, getopt)
services/gitlab/       # everything GitLab-specific
  gitlab.sh             # `_saas_gitlab` dispatcher (subcommands)
  lib/                  # cluster, versions, tls, datastore, install, runner, ssh, state, credentials
  values/               # dev.yaml.tpl / prod.yaml.tpl overlays for the gitlab/gitlab chart
tests/gitlab/
  unit/                  # fast, no real cluster (mock kubectl/helm/kind_cluster)
  e2e/                    # real, spin up a disposable kind cluster
```

A future service (e.g. a self-hosted database) is added as `services/<name>/` following the same pattern, without touching `saas.sh` beyond one new line in its `case`.
