#!/usr/bin/env bash
# ABOUTME: Bridges the Immich PostgreSQL entrypoint to libkrun's effective UID
# behavior while preserving the image-provided initialization logic.

set -euo pipefail

effective_uid="$(id -u)"
effective_gid="$(id -g)"
entrypoint="/usr/local/bin/immich-docker-entrypoint.sh"

case "${effective_uid}" in
    0)
        printf '%s\n' \
            "immich-database entrypoint: effective identity ${effective_uid}:${effective_gid}; " \
            "dropping to 1000:1000 via gosu" >&2
        exec gosu 1000:1000 "${entrypoint}" "$@"
        ;;
    1000)
        if [[ "${effective_gid}" != 1000 ]]; then
            printf '%s\n' \
                "immich-database entrypoint: unsupported identity ${effective_uid}:${effective_gid}; " \
                "UID 1000 requires GID 1000" >&2
            exit 1
        fi
        printf '%s\n' \
            "immich-database entrypoint: using existing identity ${effective_uid}:${effective_gid}" >&2
        exec "${entrypoint}" "$@"
        ;;
    *)
        printf '%s\n' \
            "immich-database entrypoint: unsupported effective UID ${effective_uid}; " \
            "expected 0 or 1000" >&2
        exit 1
        ;;
esac
