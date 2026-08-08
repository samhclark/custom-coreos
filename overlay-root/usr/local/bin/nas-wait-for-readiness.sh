#!/bin/bash
# ABOUTME: Waits for a typed startup readiness target with a bounded timeout.

set -euo pipefail

if (( $# < 4 )); then
    echo "usage: $0 marker|http TARGET TIMEOUT_SECONDS INTERVAL_SECONDS [PATH=SOURCE ...]" >&2
    exit 2
fi

mode="$1"
target="$2"
timeout_sec="$3"
interval_sec="$4"
shift 4

if [[ "${mode}" != "marker" && "${mode}" != "http" ]]; then
    echo "Unsupported readiness mode: ${mode}" >&2
    exit 2
fi
if [[ ! "${timeout_sec}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Timeout must be a positive integer: ${timeout_sec}" >&2
    exit 2
fi
if [[ ! "${interval_sec}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Interval must be a positive integer: ${interval_sec}" >&2
    exit 2
fi
if (( interval_sec > timeout_sec )); then
    echo "Interval cannot exceed timeout" >&2
    exit 2
fi
if [[ "${mode}" == "http" && $# -ne 0 ]]; then
    echo "HTTP readiness does not accept mount requirements" >&2
    exit 2
fi
for requirement in "$@"; do
    if [[ "${requirement}" != /*=* || "${requirement}" == *= ]]; then
        echo "Invalid mount requirement: ${requirement}" >&2
        exit 2
    fi
done

deadline=$((SECONDS + timeout_sec))
while (( SECONDS < deadline )); do
    if [[ "${mode}" == "marker" ]]; then
        ready=1
        [[ -e "${target}" ]] || ready=0
        if (( ready )); then
            for requirement in "$@"; do
                mount_path="${requirement%%=*}"
                expected_source="${requirement#*=}"
                actual_source="$(
                    /usr/bin/findmnt -rn -o SOURCE -T "${mount_path}" \
                        2>/dev/null
                )" || {
                    ready=0
                    break
                }
                if [[ "${actual_source}" != "${expected_source}" ]]; then
                    ready=0
                    break
                fi
            done
        fi
        (( ready )) && exit 0
    elif /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time "${interval_sec}" \
        "${target}" >/dev/null 2>&1; then
        exit 0
    fi
    sleep "${interval_sec}"
done

echo "Readiness target ${target} was not ready within ${timeout_sec} seconds" >&2
exit 1
