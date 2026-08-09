#!/bin/bash
# ABOUTME: Waits for a typed startup readiness target with a bounded timeout.

set -euo pipefail

if (( $# < 4 )); then
    echo "usage: $0 marker|http TARGET TIMEOUT_SECONDS INTERVAL_SECONDS [--path PATH [--source SOURCE] [--owner UID:GID] [--access rwx] ...]" >&2
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
    echo "HTTP readiness does not accept path requirements" >&2
    exit 2
fi

declare -a requirement_paths=()
declare -a requirement_sources=()
declare -a requirement_owners=()
declare -a requirement_access=()

while (( $# )); do
    if [[ "$1" != "--path" || $# -lt 2 || "$2" != /* ]]; then
        echo "Expected --path followed by an absolute path" >&2
        exit 2
    fi
    path="$2"
    source=""
    owner=""
    access=""
    shift 2

    while (( $# )) && [[ "$1" != "--path" ]]; do
        option="$1"
        if (( $# < 2 )); then
            echo "Missing value for path requirement option: ${option}" >&2
            exit 2
        fi
        value="$2"
        shift 2
        case "${option}" in
            --source)
                [[ -n "${value}" && -z "${source}" ]] || {
                    echo "Invalid or duplicate mount source for ${path}" >&2
                    exit 2
                }
                source="${value}"
                ;;
            --owner)
                [[ "${value}" =~ ^[0-9]+:[0-9]+$ && -z "${owner}" ]] || {
                    echo "Invalid or duplicate owner for ${path}: ${value}" >&2
                    exit 2
                }
                owner="${value}"
                ;;
            --access)
                [[ "${value}" =~ ^[rwx]+$ && -z "${access}" ]] || {
                    echo "Invalid or duplicate access mode for ${path}: ${value}" >&2
                    exit 2
                }
                access="${value}"
                ;;
            *)
                echo "Unknown path requirement option: ${option}" >&2
                exit 2
                ;;
        esac
    done

    requirement_paths+=("${path}")
    requirement_sources+=("${source}")
    requirement_owners+=("${owner}")
    requirement_access+=("${access}")
done

deadline=$((SECONDS + timeout_sec))
while (( SECONDS < deadline )); do
    if [[ "${mode}" == "marker" ]]; then
        ready=1
        [[ -e "${target}" ]] || ready=0
        if (( ready )); then
            for index in "${!requirement_paths[@]}"; do
                path="${requirement_paths[index]}"
                source="${requirement_sources[index]}"
                owner="${requirement_owners[index]}"
                access="${requirement_access[index]}"

                if [[ ! -e "${path}" ]]; then
                    ready=0
                    break
                fi
                if [[ -n "${source}" ]]; then
                    actual_source="$(
                        /usr/bin/findmnt -rn -o SOURCE -T "${path}" \
                            2>/dev/null
                    )" || {
                        ready=0
                        break
                    }
                    if [[ "${actual_source}" != "${source}" ]]; then
                        ready=0
                        break
                    fi
                fi
                if [[ -n "${owner}" && \
                    "$(/usr/bin/stat -c %u:%g "${path}" 2>/dev/null)" != "${owner}" ]]; then
                    ready=0
                    break
                fi
                [[ "${access}" != *r* || -r "${path}" ]] || ready=0
                [[ "${access}" != *w* || -w "${path}" ]] || ready=0
                [[ "${access}" != *x* || -x "${path}" ]] || ready=0
                (( ready )) || break
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
