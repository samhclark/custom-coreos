#!/usr/bin/env bash
set -euo pipefail

ZFS_STREAM="${1:-zfs-2.4}"
gh_bin="${GH_BIN:-gh}"
jq_bin="${JQ_BIN:-jq}"

version="$("${gh_bin}" release list \
    --repo openzfs/zfs \
    --json publishedAt,tagName \
    --limit 100 | \
    "${jq_bin}" -r --arg stream "${ZFS_STREAM}" \
        '[.[] | select(.tagName | startswith($stream))] | sort_by(.publishedAt) | last | (.tagName // empty) | ltrimstr("zfs-")')"

if [[ -z "${version}" || "${version}" == "null" ]]; then
    echo "No ZFS release found for stream ${ZFS_STREAM}" >&2
    exit 1
fi
printf '%s\n' "${version}"
