#!/usr/bin/env bash
set -euo pipefail

RETENTION_DAYS="${1:-30}"

printf "\033[34mTesting cleanup logic (dry run, retention: %s days)\033[0m\n" "${RETENTION_DAYS}"

cutoff_date=$(date -d "${RETENTION_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
printf "Cutoff: %s\n\n" "${cutoff_date}"

versions_json=$(gh api "/user/packages/container/custom-coreos/versions" --paginate)

if [[ -z "${versions_json}" || "${versions_json}" == "[]" ]]; then
    printf "No container images found\n"
    exit 0
fi

total_versions=$(echo "${versions_json}" | jq length)
printf "Found %s total versions:\n" "${total_versions}"
echo "${versions_json}" | jq -r '.[] | "  \(.metadata.container.tags[]? // "<untagged>") - \(.created_at) - ID: \(.id)"' | sort
echo ""

old_versions=$(echo "${versions_json}" | jq -r --arg cutoff "${cutoff_date}" \
    '.[] | select(.created_at < $cutoff) | "  \(.metadata.container.tags[]? // "<untagged>") - \(.created_at) - ID: \(.id)"')

if [[ -z "${old_versions}" ]]; then
    printf "\033[32mNo versions older than %s days\033[0m\n" "${RETENTION_DAYS}"
else
    deletion_count=$(echo "${old_versions}" | wc -l)
    remaining_count=$((total_versions - deletion_count))
    printf "\033[31mWould delete (%s versions):\033[0m\n" "${deletion_count}"
    echo "${old_versions}"
    echo ""
    printf "Total: %s  To delete: %s  To keep: %s\n" \
        "${total_versions}" "${deletion_count}" "${remaining_count}"
    printf "\033[34mDry run — no deletion performed\033[0m\n"
fi
