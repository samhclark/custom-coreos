#!/bin/bash
# ABOUTME: Refuses a rootless TAP service start when a host TCP port is busy.

set -euo pipefail

if (( $# == 0 )); then
    echo "usage: $0 PORT [PORT ...]" >&2
    exit 2
fi

for port in "$@"; do
    if [[ ! "${port}" =~ ^[1-9][0-9]*$ ]] || (( 10#${port} > 65535 )); then
        echo "Invalid TCP port: ${port}" >&2
        exit 2
    fi

    listeners="$(/usr/bin/ss -H -ltn "sport = :${port}")"
    if [[ -n "${listeners}" ]]; then
        echo "Refusing to start while a process listens on host TCP port ${port}" >&2
        exit 1
    fi
done
