#!/usr/bin/env bash
# ABOUTME: Queries GHCR versions and delegates cleanup selection to a pure planner.

set -euo pipefail

if (( $# > 0 )); then
    retention_days="$1"
    shift
else
    retention_days=90
fi
if [[ ! "${retention_days}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Retention days must be a positive integer: ${retention_days}" >&2
    exit 2
fi

planner_args=()
if (( $# > 0 )); then
    if [[ "${1:-}" != "--github-output" || $# != 2 ]]; then
        echo "usage: $0 [RETENTION_DAYS] [--github-output PATH]" >&2
        exit 2
    fi
    planner_args=(--github-output "$2")
fi

gh_bin="${GH_BIN:-gh}"
date_bin="${DATE_BIN:-date}"
python_bin="${PYTHON_BIN:-python3}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cutoff="$(
    "${date_bin}" -d "${retention_days} days ago" -u +%Y-%m-%dT%H:%M:%SZ
)"

versions_json="$(
    "${gh_bin}" api "/user/packages/container/custom-coreos/versions" --paginate
)"
printf '%s\n' "${versions_json}" \
    | "${python_bin}" "${script_dir}/plan-image-cleanup.py" \
        --cutoff "${cutoff}" "${planner_args[@]}"
