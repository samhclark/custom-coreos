#!/bin/bash
# ABOUTME: Creates one namespaced ZFS snapshot and prunes its cadence safely.

set -euo pipefail

if (( $# != 3 )); then
    echo "usage: $0 DATASET CADENCE RETENTION_COUNT" >&2
    exit 2
fi

dataset="$1"
cadence="$2"
retention="$3"
zfs_bin="${ZFS_BIN:-/usr/sbin/zfs}"
date_bin="${DATE_BIN:-/usr/bin/date}"

if [[ "${dataset}" != tank/* || "${dataset}" == *@* ]] \
    || [[ "${dataset}" =~ [[:space:]] ]]; then
    echo "Dataset must be a child of tank without whitespace or @: ${dataset}" >&2
    exit 2
fi
case "${cadence}" in
    frequently|hourly|daily|weekly|monthly|yearly) ;;
    *)
        echo "Unsupported snapshot cadence: ${cadence}" >&2
        exit 2
        ;;
esac
if [[ ! "${retention}" =~ ^[0-9]+$ ]]; then
    echo "Retention must be a non-negative integer: ${retention}" >&2
    exit 2
fi

is_managed_snapshot() {
    local name="$1"
    local suffix

    [[ "${name}" == "${dataset}@"* ]] || return 1
    suffix="${name#"${dataset}@"}"
    if [[ "${suffix}" =~ ^nas-auto-${cadence}-[0-9]{8}T[0-9]{6}Z$ ]]; then
        return 0
    fi

    # Include names emitted by the six retired rotation scripts so the first
    # run migrates their retention window instead of preserving them forever.
    case "${cadence}" in
        frequently)
            [[ "${suffix}" =~ ^(00|15|30|45|60)-minutes-ago$ ]]
            ;;
        hourly)
            [[ "${suffix}" =~ ^(0-hours-ago|1-hour-ago|([2-9]|1[0-9]|2[0-4])-hours-ago)$ ]]
            ;;
        daily)
            [[ "${suffix}" =~ ^(today|yesterday|[2-7]-days-ago)$ ]]
            ;;
        weekly)
            [[ "${suffix}" =~ ^(this-week|last-week|[2-4]-weeks-ago)$ ]]
            ;;
        monthly)
            [[ "${suffix}" =~ ^(this-month|last-month|([2-9]|1[0-2])-months-ago)$ ]]
            ;;
        yearly)
            [[ "${suffix}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
            ;;
    esac
}

"${zfs_bin}" list -H -o name "${dataset}" >/dev/null
timestamp="$("${date_bin}" --utc +%Y%m%dT%H%M%SZ)"
if [[ ! "${timestamp}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "Date command returned an invalid UTC timestamp: ${timestamp}" >&2
    exit 1
fi
new_snapshot="${dataset}@nas-auto-${cadence}-${timestamp}"
if ! "${zfs_bin}" snapshot "${new_snapshot}"; then
    # Creation may have completed before an earlier invocation was interrupted.
    # Resume pruning only if the exact intended snapshot demonstrably exists.
    if [[ "$("${zfs_bin}" list -H -o name "${new_snapshot}" 2>/dev/null)" \
        != "${new_snapshot}" ]]; then
        echo "Unable to create or find ${new_snapshot}" >&2
        exit 1
    fi
fi

# A retention of zero is the explicit keep-forever policy used by yearly.
(( retention == 0 )) && exit 0

managed=()
if ! snapshot_listing="$(
    "${zfs_bin}" list -H -p -o name,creation -t snapshot
)"; then
    echo "Unable to enumerate snapshots after creating ${new_snapshot}" >&2
    exit 1
fi
while IFS=$'\t' read -r name creation; do
    if is_managed_snapshot "${name}"; then
        managed+=("${creation}"$'\t'"${name}")
    fi
done <<< "${snapshot_listing}"

excess=$(( ${#managed[@]} - retention ))
(( excess > 0 )) || exit 0

mapfile -t oldest_first < <(
    printf '%s\n' "${managed[@]}" | /usr/bin/sort -n -k1,1 -k2,2
)
for (( index = 0; index < excess; index++ )); do
    snapshot="${oldest_first[index]#*$'\t'}"
    "${zfs_bin}" destroy "${snapshot}"
done
