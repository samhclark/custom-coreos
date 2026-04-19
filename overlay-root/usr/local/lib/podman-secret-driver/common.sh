#!/bin/bash
# ABOUTME: Shared helpers for the Podman shell secret driver scripts.

set -euo pipefail

podman_secret_host_uid() {
    local current_uid
    local ns_start
    local host_start
    local length

    current_uid="$(id -u)"

    if [[ -r /proc/self/uid_map ]]; then
        while read -r ns_start host_start length; do
            if (( current_uid >= ns_start && current_uid < ns_start + length )); then
                printf '%s\n' "$((host_start + current_uid - ns_start))"
                return
            fi
        done < /proc/self/uid_map
    fi

    printf '%s\n' "${current_uid}"
}

podman_secret_store_context() {
    local host_uid
    local user

    host_uid="$(podman_secret_host_uid)"

    if [[ "${host_uid}" -eq 0 ]]; then
        SECRET_STORE_DIR="/var/lib/podman-secrets"
        SECRET_CREDS_MODE=()
        return
    fi

    user="$(getent passwd "${host_uid}" | cut -d: -f1 || true)"
    if [[ -z "${user}" ]]; then
        echo "ERROR: No passwd entry for host UID ${host_uid}" >&2
        exit 1
    fi

    SECRET_STORE_DIR="/var/lib/podman-secrets/${user}"
    SECRET_CREDS_MODE=(--user)
}
