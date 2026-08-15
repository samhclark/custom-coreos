#!/usr/bin/env bash
# ABOUTME: Creates and validates the empty media-automation directory layout.

set -euo pipefail

export LC_ALL=C

ROOT=/var/zfs/tank/videos
EXPECTED_SOURCE=tank/videos
SHARED_GID=52000

required_paths=(
    "$ROOT"
    "$ROOT/data"
    "$ROOT/data/media"
    "$ROOT/data/media/movies"
    "$ROOT/data/media/tv"
    "$ROOT/data/usenet"
    "$ROOT/data/usenet/incomplete"
    "$ROOT/data/usenet/complete"
    "$ROOT/data/usenet/complete/movies"
    "$ROOT/data/usenet/complete/tv"
)

destination_paths=(
    "$ROOT/data/media/movies"
    "$ROOT/data/media/tv"
    "$ROOT/data/usenet/incomplete"
    "$ROOT/data/usenet/complete/movies"
    "$ROOT/data/usenet/complete/tv"
)

source_paths=(
    "$ROOT/movies"
    "$ROOT/tv-shows"
)

if ((EUID != 0)); then
    printf 'Run this operation as root: sudo bash %q\n' "$0" >&2
    exit 1
fi

for command in chmod chown find findmnt install stat; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

require_real_directory() {
    local path=$1

    if [[ -L "$path" ]]; then
        fail "Refusing symlink: $path"
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
        fail "Expected a directory, found another file type: $path"
    fi
}

verify_on_media_dataset() {
    local path=$1
    local source device

    source=$(findmnt -n -o SOURCE -T "$path")
    if [[ "$source" != "$EXPECTED_SOURCE" ]]; then
        fail "Path is not on $EXPECTED_SOURCE: $path (source=$source)"
    fi
    device=$(stat -c '%d' -- "$path")
    if [[ "$device" != "$root_device" ]]; then
        fail "Path is on a different device: $path (device=$device root_device=$root_device)"
    fi
}

verify_source() {
    local path=$1
    local source device

    require_real_directory "$path"
    if [[ ! -d "$path" ]]; then
        fail "Required existing source directory is missing: $path"
    fi
    source=$(findmnt -n -o SOURCE -T "$path")
    if [[ "$source" != "$EXPECTED_SOURCE" ]]; then
        fail "Source is not on $EXPECTED_SOURCE: $path (source=$source)"
    fi
    device=$(stat -c '%d' -- "$path")
    if [[ "$device" != "$root_device" ]]; then
        fail "Source is on a different device: $path (device=$device root_device=$root_device)"
    fi
}

verify_exact_metadata() {
    local path=$1
    local metadata

    metadata=$(stat -c '%u:%g %a' -- "$path")
    if [[ "$metadata" != "0:${SHARED_GID} 2775" ]]; then
        fail "Unexpected ownership or mode: $path (found=$metadata expected=0:${SHARED_GID} 2775)"
    fi
}

require_real_directory "$ROOT"
if [[ ! -d "$ROOT" ]]; then
    fail "Media root is missing: $ROOT"
fi

root_mount_target=$(findmnt -n -o TARGET -T "$ROOT")
root_mount_source=$(findmnt -n -o SOURCE -T "$ROOT")
if [[ "$root_mount_target" != "$ROOT" || "$root_mount_source" != "$EXPECTED_SOURCE" ]]; then
    fail "Expected $ROOT mounted from $EXPECTED_SOURCE; found target=$root_mount_target source=$root_mount_source"
fi
root_device=$(stat -c '%d' -- "$ROOT")

for source in "${source_paths[@]}"; do
    verify_source "$source"
done
movies_before=$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "${source_paths[0]}")
tv_before=$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "${source_paths[1]}")

# Existing layout parents may contain only the expected children. This keeps
# the operation directory-only and prevents it from silently adopting an
# unrelated tree under data.
for path in "${required_paths[@]}"; do
    require_real_directory "$path"
    if [[ -e "$path" ]]; then
        verify_on_media_dataset "$path"
    fi
done

if [[ -d "$ROOT/data" ]]; then
    unexpected=$(find -P "$ROOT/data" -mindepth 1 -maxdepth 1 \
        ! \( -name media -o -name usenet \) -print -quit)
    if [[ -n "$unexpected" ]]; then
        fail "Unexpected entry under $ROOT/data: $unexpected"
    fi
fi
if [[ -d "$ROOT/data/media" ]]; then
    unexpected=$(find -P "$ROOT/data/media" -mindepth 1 -maxdepth 1 \
        ! \( -name movies -o -name tv \) -print -quit)
    if [[ -n "$unexpected" ]]; then
        fail "Unexpected entry under $ROOT/data/media: $unexpected"
    fi
fi
if [[ -d "$ROOT/data/usenet" ]]; then
    unexpected=$(find -P "$ROOT/data/usenet" -mindepth 1 -maxdepth 1 \
        ! \( -name incomplete -o -name complete \) -print -quit)
    if [[ -n "$unexpected" ]]; then
        fail "Unexpected entry under $ROOT/data/usenet: $unexpected"
    fi
fi
if [[ -d "$ROOT/data/usenet/complete" ]]; then
    unexpected=$(find -P "$ROOT/data/usenet/complete" -mindepth 1 -maxdepth 1 \
        ! \( -name movies -o -name tv \) -print -quit)
    if [[ -n "$unexpected" ]]; then
        fail "Unexpected entry under $ROOT/data/usenet/complete: $unexpected"
    fi
fi

for path in "${destination_paths[@]}"; do
    if [[ -d "$path" ]] && [[ -n "$(find -P "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        fail "Destination is populated: $path"
    fi
done

# All validation above is complete before this point. Missing paths are the
# only filesystem objects created; existing empty directories may have their
# declared ownership and mode restored below.
for path in "${required_paths[@]}"; do
    if [[ ! -e "$path" ]]; then
        install -d -- "$path"
    fi
done

for path in "${required_paths[@]}"; do
    chown "root:${SHARED_GID}" -- "$path"
    chmod 2775 -- "$path"
done

for path in "${required_paths[@]}"; do
    require_real_directory "$path"
    verify_on_media_dataset "$path"
    verify_exact_metadata "$path"
done

root_mount_target=$(findmnt -n -o TARGET -T "$ROOT")
root_mount_source=$(findmnt -n -o SOURCE -T "$ROOT")
if [[ "$root_mount_target" != "$ROOT" || "$root_mount_source" != "$EXPECTED_SOURCE" ]]; then
    fail "Media mount changed during operation: target=$root_mount_target source=$root_mount_source"
fi

movies_after=$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "${source_paths[0]}")
tv_after=$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "${source_paths[1]}")
if [[ "$movies_before" != "$movies_after" || "$tv_before" != "$tv_after" ]]; then
    fail 'An existing media source changed while creating the empty layout'
fi
for source in "${source_paths[@]}"; do
    verify_source "$source"
done

printf 'Validated media mount: target=%s source=%s device=%s\n' \
    "$root_mount_target" "$root_mount_source" "$root_device"
printf '%s\n' 'Validated layout directories (owner:group mode):'
for path in "${required_paths[@]}"; do
    printf '  %s %s %s\n' "$(stat -c '%u:%g' -- "$path")" \
        "$(stat -c '%a' -- "$path")" "$path"
done
printf 'Preserved existing source: %s fingerprint=%s\n' "${source_paths[0]}" "$movies_after"
printf 'Preserved existing source: %s fingerprint=%s\n' "${source_paths[1]}" "$tv_after"
printf '%s\n' 'No media files were moved or modified; this phase created or normalized directories only.'
