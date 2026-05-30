#!/usr/bin/env bash
set -euo pipefail

ZFS_STREAM="${1:-zfs-2.4}"

gh release list \
    --repo openzfs/zfs \
    --json publishedAt,tagName \
    --limit 100 | \
    jq -r --arg stream "${ZFS_STREAM}" \
        '[.[] | select(.tagName | startswith($stream))] | sort_by(.publishedAt) | last | .tagName | ltrimstr("zfs-")'
