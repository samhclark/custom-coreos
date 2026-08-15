#!/usr/bin/env bash
# ABOUTME: Adapts the Prowlarr image entrypoint to libkrun's rootless identity.

set -euo pipefail

umask 002

effective_uid="$(id -u)"
effective_gid="$(id -g)"
readonly effective_uid effective_gid
readonly temp_dir="/run/prowlarr-temp"

prepare_temp_dir() {
    mkdir -p "${temp_dir}"
    chown 1000:1000 "${temp_dir}"
}

case "${effective_uid}" in
    0)
        prepare_temp_dir
        exec s6-setuidgid 1000:1000 \
            /app/prowlarr/bin/Prowlarr -nobrowser -data=/config "$@"
        ;;
    1000)
        if [[ "${effective_gid}" != 1000 ]]; then
            printf '%s\n' \
                "prowlarr entrypoint: unsupported identity ${effective_uid}:${effective_gid}; " \
                "UID 1000 requires GID 1000" >&2
            exit 1
        fi
        exec /app/prowlarr/bin/Prowlarr -nobrowser -data=/config "$@"
        ;;
    *)
        printf '%s\n' \
            "prowlarr entrypoint: unsupported effective identity ${effective_uid}:${effective_gid}; " \
            "expected root or 1000:1000" >&2
        exit 1
        ;;
esac
