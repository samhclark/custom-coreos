#!/usr/bin/env bash
# ABOUTME: Adapts the SABnzbd image entrypoint to libkrun's rootless identity.

set -euo pipefail

umask 002

effective_uid="$(id -u)"
effective_gid="$(id -g)"
readonly effective_uid effective_gid

if [[ -e /proc/net/if_inet6 ]]; then
    readonly family="::"
else
    readonly family="0.0.0.0"
fi

case "${effective_uid}" in
    0)
        exec s6-setuidgid 1000:1000 \
            python3 /app/sabnzbd/SABnzbd.py --config-file /config \
            --server "${family}" "$@"
        ;;
    1000)
        if [[ "${effective_gid}" != 1000 ]]; then
            printf '%s\n' \
                "sabnzbd entrypoint: unsupported identity ${effective_uid}:${effective_gid}; " \
                "UID 1000 requires GID 1000" >&2
            exit 1
        fi
        exec python3 /app/sabnzbd/SABnzbd.py --config-file /config \
            --server "${family}" "$@"
        ;;
    *)
        printf '%s\n' \
            "sabnzbd entrypoint: unsupported effective identity ${effective_uid}:${effective_gid}; " \
            "expected root or 1000:1000" >&2
        exit 1
        ;;
esac
