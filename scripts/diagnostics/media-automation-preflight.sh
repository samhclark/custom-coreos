#!/usr/bin/env bash
# ABOUTME: Collects read-only NAS storage evidence before the media-automation migration.

set -euo pipefail

export LC_ALL=C

MEDIA_ROOT=/var/zfs/tank/videos

if ((EUID != 0)); then
    printf 'Run this read-only preflight as root: sudo bash %q\n' "$0" >&2
    exit 1
fi

for command in find findmnt stat zfs zpool; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

printf '%s\n' '--- dataset ---'
findmnt -T "$MEDIA_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -R "$MEDIA_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS
zfs list -r -o name,mountpoint,mounted tank/videos

printf '%s\n' '--- current paths ---'
for path in \
    "$MEDIA_ROOT" \
    "$MEDIA_ROOT/movies" \
    "$MEDIA_ROOT/tv-shows" \
    "$MEDIA_ROOT/data" \
    "$MEDIA_ROOT/data/media" \
    "$MEDIA_ROOT/data/usenet"; do
    if [[ -e "$path" || -L "$path" ]]; then
        stat -c '%F %u:%g %a %n' -- "$path"
        ls -Zd -- "$path"
    else
        printf 'MISSING %s\n' "$path"
    fi
done

printf '%s\n' '--- top-level contents ---'
find "$MEDIA_ROOT" -mindepth 1 -maxdepth 1 \
    -printf '%y %u:%g %m %p\n'

printf '%s\n' '--- source tree audit ---'
for source in "$MEDIA_ROOT/movies" "$MEDIA_ROOT/tv-shows"; do
    if [[ -d "$source" && ! -L "$source" ]]; then
        printf 'SOURCE %s\n' "$source"
        find -P "$source" -xdev -printf '%y\n' | sort | uniq -c
        printf '%s\n' 'first 20 symlinks (not followed):'
        find -P "$source" -xdev -type l -printf '%p -> %l\n' |
            sed -n '1,20p'
    fi
done

printf '%s\n' '--- space ---'
df -hT "$MEDIA_ROOT"
zpool list -p tank

printf '%s\n' '--- end ---'
printf '%s\n' 'No services, datasets, files, ownership, modes, or labels were changed.'
