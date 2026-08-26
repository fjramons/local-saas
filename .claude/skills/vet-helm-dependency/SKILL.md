---
name: vet-helm-dependency
description: Checklist for vetting a candidate third-party Helm chart or operator before adopting it in this repo. Use before adding any new 'helm repo add'/OCI chart dependency to services/gitlab/lib/operators.sh (or any future service), not just when the user asks to "check" a dependency, but proactively whenever a new one is about to be wired in.
---

# Vetting a third-party Helm chart/operator

This repo pins exact versions for any third-party Helm chart it depends on (see CLAUDE.md, "Pinned versions"). Reproducibility across `install`/`up` cycles is a hard requirement, not a nice-to-have. A dependency that can't be pinned, or that stops receiving fixes, breaks that promise silently. This checklist codifies exactly what disqualified two real candidates while implementing GitLab's HA datastore support: Bitnami's Redis chart (paywalled/unpinnable catalog since August 2025) and `spotahome/redis-operator` (archived upstream since June 2026); both looked reasonable at first glance and only failed on these specific checks.

Run every check below before adding a new chart/operator dependency. If more than one candidate exists, run the checklist on all of them and compare.

## 1. Archived-repo check

```bash
gh repo view OWNER/REPO --json isArchived,pushedAt,archivedAt
```

- `isArchived: true` → **disqualified**, no exceptions. An archived repo gets no security patches and no compatibility fixes for future Kubernetes/cert-manager/etc. API changes.
- Cross-check `pushedAt` even if not archived: a repo can go quiet for years without being formally archived.

## 2. Recent-activity check

- Last commit/release within roughly the last 12 months is the bar. Older than that, treat it as at-risk even if not archived. Check open issues for "is this maintained?"-style questions and how (or whether) they were answered.
- `gh repo view OWNER/REPO --json pushedAt` or check the releases page directly.

## 3. Real, pinnable releases, not just `:latest`

- Confirm actual semver-tagged releases exist, reachable with a concrete version pin:
  - Classic Helm repo: `helm search repo REPO/CHART --versions` must list more than one real version.
  - OCI chart: `helm show chart oci://HOST/PATH/CHART --version X.Y.Z` must succeed for a specific `X.Y.Z`, not just an unqualified pull.
- A project offering only `:latest` (no versioned tags/releases) fails this check outright. This is exactly the Bitnami situation (since August 2025, free-tier images/charts dropped version pinning; full versioned catalog moved behind a paid subscription). Don't special-case "just this once": pin or don't use it.
- **Verify the chart repo itself is actually reachable**, not just that a page cites it: a `helm repo add`/`helm pull` against the actual URL, not just trusting a README's stated install instructions. An outdated README can point at a GitHub Pages Helm repo that 404s while the project moved to OCI distribution (or vice versa). This exact gap was found this session: an early research pass cited a `ebrianne.github.io/helm-charts` repo that no longer resolves; the project's actual current successor distributes via `oci://ghcr.io/...` instead.

## 4. License/paywall check

- The chart AND the images it deploys must be fully usable without a paid subscription. Confirm by actually pulling (`helm pull`, `docker pull`/`crane manifest`) rather than trusting marketing copy. A "community tier" that only ships a reduced, `:latest`-only subset (Bitnami's current model) fails both this check and check #3.

## 5. RBAC/CRD footprint review

- Read the chart's own RBAC templates (`ClusterRole`/`ClusterRoleBinding`/`Role`) before installing. Note anything scoped wider than the feature needs, and anything scoped narrower than you assumed (e.g. a webhook's Secret-read `Role` scoped by `resourceNames` to exactly one fixed secret name, discovered this way for `cert-manager-webhook-duckdns`, which forces a single shared cluster-wide token rather than one per release).
- Note every new CRD it installs (`kubectl get crd` before/after, or read `crds/*.yaml` in the chart). These are cluster-wide and outlive `helm uninstall` unless explicitly cleaned up.

## 6. Maintainer-count/bus-factor check

- Single-maintainer hobby project vs. an organization/CNCF-backed one: check `gh repo view OWNER/REPO --json owner` and the contributors graph.
- A single-maintainer project isn't automatically disqualified (this repo's DuckDNS webhook is exactly that), but it requires an **explicit, scoped, case-by-case sign-off** from whoever's driving the work. Never adopt one silently as if it were as safe a default as an org-backed project. Document the choice and the reasoning in `CLAUDE.md` the same way the DuckDNS exception is documented there.

## Recording the outcome

Whatever the verdict, write it down in `CLAUDE.md` next to the dependency (or, if rejected, next to the one that was chosen instead). A rejected candidate with the reasoning is exactly what let this checklist exist in the first place. Include: the exact check that passed/failed, the date/version state it was checked against (these things change), and the alternative chosen if the first candidate was rejected.

## Tool: inspecting the chart's actual defaults

Once a candidate passes the checks above, `helm show values` on an umbrella chart only shows the merged, top-level view; it can hide what a specific subchart actually defaults to. Use `tools/helm-chart-extract-values.sh` (same directory tree as this skill) to pull the real chart and print every subchart's own `values.yaml` separately:

```bash
tools/helm-chart-extract-values.sh https://charts.example.com mychart 1.2.3
tools/helm-chart-extract-values.sh oci://ghcr.io/org/charts mychart 1.2.3
```
