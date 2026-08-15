#!/usr/bin/env bash
# ABOUTME: Adapts the Sonarr image entrypoint to libkrun's rootless identity.

set -euo pipefail

umask 002

effective_uid="$(id -u)"
effective_gid="$(id -g)"
readonly effective_uid effective_gid
readonly temp_dir="/run/sonarr-temp"

prepare_temp_dir() {
    mkdir -p "${temp_dir}"
    chown abc:abc "${temp_dir}"
}

case "${effective_uid}" in
    0)
        groupmod -o -g 1000 abc
        usermod -o -u 1000 -g 1000 abc
        prepare_temp_dir
        exec s6-setuidgid abc \
            /app/sonarr/bin/Sonarr -nobrowser -data=/config "$@"
        ;;
    1000)
        if [[ "${effective_gid}" != 1000 ]]; then
            printf '%s\n' \
                "sonarr entrypoint: unsupported identity ${effective_uid}:${effective_gid}; " \
                "UID 1000 requires GID 1000" >&2
            exit 1
        fi
        exec /app/sonarr/bin/Sonarr -nobrowser -data=/config "$@"
        ;;
    *)
        printf '%s\n' \
            "sonarr entrypoint: unsupported effective identity ${effective_uid}:${effective_gid}; " \
            "expected root or 1000:1000" >&2
        exit 1
        ;;
esac
