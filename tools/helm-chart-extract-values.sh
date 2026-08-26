#!/usr/bin/env bash
# tools/helm-chart-extract-values.sh REPO_URL_OR_OCI CHART VERSION [OUT_DIR]
#
# Downloads a Helm chart and prints the REAL values.yaml of the umbrella chart AND every subchart
# separately, unlike 'helm show values', which only ever returns the merged view and hides which
# specific subchart's own default a given value actually comes from. Deterministic: given the same
# REPO/CHART/VERSION it always extracts the exact same content, no 'latest', no live merging.
#
# Useful before wiring a new values overlay to an unfamiliar chart, or diffing two versions of the
# same chart during an upgrade. This exact gap (a value visible in a subchart's own values.yaml but
# absent from the umbrella chart's merged view) is how this project discovered, among other things,
# that the Container Registry subchart needs its own 'registry.storage.secret'.
#
# Usage:
#   tools/helm-chart-extract-values.sh https://charts.gitlab.io gitlab 10.3.1
#   tools/helm-chart-extract-values.sh oci://ghcr.io/cloudnative-pg/charts cloudnative-pg 0.29.0
#
# OUT_DIR defaults to a fresh temp directory (printed on stderr) and is left in place for further
# inspection. Remove it yourself when done.
set -euo pipefail

repo="${1:?Usage: $0 REPO_URL_OR_OCI CHART VERSION [OUT_DIR]}"
chart="${2:?missing CHART}"
version="${3:?missing VERSION}"
out_dir="${4:-$(mktemp -d)}"

command -v helm >/dev/null 2>&1 || { echo "helm is required." >&2; exit 1; }

mkdir -p "$out_dir"

repo_name=""
if [[ "$repo" == oci://* ]]; then
    chart_ref="${repo%/}/${chart}"
else
    repo_name="_tmp_extract_values_$$"
    helm repo add "$repo_name" "$repo" >/dev/null
    helm repo update "$repo_name" >/dev/null
    chart_ref="${repo_name}/${chart}"
fi

helm pull "$chart_ref" --version "$version" --untar --untardir "$out_dir" >/dev/null

[ -n "$repo_name" ] && helm repo remove "$repo_name" >/dev/null 2>&1

echo "# Chart extracted to: $out_dir/$chart" >&2

find "$out_dir/$chart" -name values.yaml | sort | while IFS= read -r f; do
    echo ""
    echo "## ${f#"$out_dir"/}"
    echo '```yaml'
    cat "$f"
    echo '```'
done
