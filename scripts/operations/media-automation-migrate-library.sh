#!/usr/bin/env bash
# ABOUTME: Safely renames the existing media libraries into the shared layout.

set -euo pipefail

export LC_ALL=C

ROOT=/var/zfs/tank/videos
EXPECTED_SOURCE=tank/videos
SHARED_GID=52000
JELLYFIN_UID=51120
JELLYFIN_MANAGER="user@${JELLYFIN_UID}.service"
SOURCE_MOVIES="$ROOT/movies"
SOURCE_TV="$ROOT/tv-shows"
DEST_MOVIES="$ROOT/data/media/movies"
DEST_TV="$ROOT/data/media/tv"

required_paths=(
    "$ROOT"
    "$ROOT/data"
    "$ROOT/data/media"
    "$DEST_MOVIES"
    "$DEST_TV"
    "$ROOT/data/usenet"
    "$ROOT/data/usenet/incomplete"
    "$ROOT/data/usenet/complete"
    "$ROOT/data/usenet/complete/movies"
    "$ROOT/data/usenet/complete/tv"
)

source_paths=("$SOURCE_MOVIES" "$SOURCE_TV")
destination_paths=("$DEST_MOVIES" "$DEST_TV")

if ((EUID != 0)); then
    printf 'Run this operation as root: sudo bash %q\n' "$0" >&2
    exit 1
fi

for command in chmod chgrp chown find findmnt grep install mv pgrep readlink rmdir stat systemctl wc; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

mv_help=$(mv --help)
if ! grep -Fq -- '--no-copy' <<< "$mv_help"; then
    printf '%s\n' 'This migration requires mv --no-copy to forbid copy-and-delete fallback.' >&2
    exit 1
fi

fail() {
    printf 'ABORTED: %s\n' "$1" >&2
    exit 1
}

require_real_directory() {
    local path=$1

    if [[ -L "$path" ]]; then
        fail "Refusing symlink where a directory is required: $path"
    fi
    if [[ ! -d "$path" ]]; then
        fail "Required real directory is missing: $path"
    fi
}

verify_mount_source_and_device() {
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

verify_exact_root_metadata() {
    local path=$1
    local metadata

    metadata=$(stat -c '%u:%g %a' -- "$path")
    if [[ "$metadata" != "0:${SHARED_GID} 2775" ]]; then
        fail "Unexpected required-root metadata: $path (found=$metadata expected=0:${SHARED_GID} 2775)"
    fi
}

verify_required_root() {
    local path=$1

    require_real_directory "$path"
    verify_mount_source_and_device "$path"
    verify_exact_root_metadata "$path"
}

verify_exact_media_mount() {
    local mount_record root_mount_target root_mount_source

    require_real_directory "$ROOT"
    if ! mount_record=$(findmnt -n -o TARGET,SOURCE --mountpoint "$ROOT"); then
        fail "Unable to find the exact mount at $ROOT"
    fi
    read -r root_mount_target root_mount_source <<< "$mount_record"
    if [[ "$root_mount_target" != "$ROOT" || "$root_mount_source" != "$EXPECTED_SOURCE" ]]; then
        fail "Expected exact mount $ROOT from $EXPECTED_SOURCE; found target=$root_mount_target source=$root_mount_source"
    fi

    root_device=$(stat -c '%d' -- "$ROOT")

    local nested_mounts
    if ! nested_mounts=$(findmnt -R -n -o TARGET --mountpoint "$ROOT"); then
        fail "Unable to inspect mounts below $ROOT"
    fi
    while IFS= read -r mount_target; do
        [[ -n "$mount_target" && "$mount_target" != "$ROOT" ]] || continue
        fail "Refusing nested mount below $ROOT: $mount_target"
    done <<< "$nested_mounts"

    printf 'Validated exact media mount: target=%s source=%s device=%s\n' \
        "$root_mount_target" "$root_mount_source" "$root_device"
}

verify_source_tree_types() {
    local source=$1
    local unexpected

    if ! unexpected=$(find -P "$source" -xdev \
        ! \( -type d -o -type f -o -type l \) -print -quit); then
        fail "Unable to inspect source tree file types: $source"
    fi
    if [[ -n "$unexpected" ]]; then
        fail "Unsupported file type in source tree: $unexpected"
    fi
}

verify_empty_destination() {
    local destination=$1
    local unexpected

    require_real_directory "$destination"
    verify_mount_source_and_device "$destination"
    if ! unexpected=$(find -P "$destination" -mindepth 1 -maxdepth 1 \
        -print -quit); then
        fail "Unable to inspect destination: $destination"
    fi
    if [[ -n "$unexpected" ]]; then
        fail "Destination is not empty: $destination (first entry=$unexpected)"
    fi
}

verify_jellyfin_stopped() {
    local manager_state remaining_processes pgrep_status

    if ! manager_state=$(systemctl show --property=ActiveState --value \
        "$JELLYFIN_MANAGER"); then
        fail "Unable to inspect $JELLYFIN_MANAGER"
    fi
    if [[ "$manager_state" != inactive ]]; then
        fail "Refusing to migrate while $JELLYFIN_MANAGER is $manager_state"
    fi

    set +e
    remaining_processes=$(pgrep -a -u "$JELLYFIN_UID" 2>&1)
    pgrep_status=$?
    set -e
    case "$pgrep_status" in
        0)
            printf 'Processes still owned by UID %s:\n%s\n' \
                "$JELLYFIN_UID" "$remaining_processes" >&2
            fail "Jellyfin-owned processes remain"
            ;;
        1)
            ;;
        *)
            fail "Unable to inspect processes for UID $JELLYFIN_UID: $remaining_processes"
            ;;
    esac

    printf 'Validated Jellyfin stopped: %s inactive, no UID %s processes\n' \
        "$JELLYFIN_MANAGER" "$JELLYFIN_UID"
}

target_is_source_tree() {
    local target=$1
    local source

    for source in "${source_paths[@]}"; do
        case "$target" in
            "$source"|"$source/"*|"$source (deleted)"|"$source/"*" (deleted)")
                return 0
                ;;
        esac
    done
    return 1
}

scan_media_process_references() {
    local proc_dir pid fd_dir fd_path fd target link_name link_path
    local process_name scan_error=0 media_reference=0
    local -a fd_paths=()

    if [[ ! -d /proc || ! -r /proc ]]; then
        fail 'Cannot perform the required /proc file-descriptor scan'
    fi

    shopt -s nullglob
    for proc_dir in /proc/[0-9]*; do
        [[ -d "$proc_dir" ]] || continue
        pid=${proc_dir##*/}
        fd_dir="$proc_dir/fd"
        if [[ ! -d "$fd_dir" ]]; then
            [[ -d "$proc_dir" ]] || continue
            printf 'Unable to inspect file descriptors for PID %s\n' "$pid" >&2
            scan_error=1
            continue
        fi
        if [[ ! -r "$fd_dir" ]]; then
            [[ -d "$proc_dir" ]] || continue
            printf 'Unable to read file descriptors for PID %s\n' "$pid" >&2
            scan_error=1
            continue
        fi

        # Kernel threads legitimately have an unresolvable /proc/<pid>/exe.
        # Executable mappings are not writer capabilities, so inspect the
        # process working directory and root plus every open FD instead.
        for link_name in cwd root; do
            link_path="$proc_dir/$link_name"
            if [[ ! -e "$link_path" && ! -L "$link_path" ]]; then
                continue
            fi
            if ! target=$(readlink -- "$link_path"); then
                [[ -d "$proc_dir" ]] || continue
                printf 'Unable to resolve PID %s %s\n' "$pid" "$link_name" >&2
                scan_error=1
                continue
            fi
            if target_is_source_tree "$target"; then
                process_name='unknown'
                if [[ -r "$proc_dir/comm" ]]; then
                    IFS= read -r process_name < "$proc_dir/comm" || process_name=unknown
                fi
                printf 'Media process reference detected: PID=%s command=%q reference=%s path=%q\n' \
                    "$pid" "$process_name" "$link_name" "$target" >&2
                media_reference=1
            fi
        done

        fd_paths=("$fd_dir"/*)
        for fd_path in "${fd_paths[@]}"; do
            [[ -e "$fd_path" || -L "$fd_path" ]] || continue
            fd=${fd_path##*/}
            if ! target=$(readlink -- "$fd_path"); then
                [[ -e "$fd_path" || -L "$fd_path" ]] || continue
                [[ -d "$proc_dir" ]] || continue
                printf 'Unable to resolve PID %s FD %s\n' "$pid" "$fd" >&2
                scan_error=1
                continue
            fi
            if target_is_source_tree "$target"; then
                process_name='unknown'
                if [[ -r "$proc_dir/comm" ]]; then
                    IFS= read -r process_name < "$proc_dir/comm" || process_name=unknown
                fi
                printf 'Open media FD detected: PID=%s command=%q FD=%s path=%q\n' \
                    "$pid" "$process_name" "$fd" "$target" >&2
                media_reference=1
            fi
        done
    done
    shopt -u nullglob

    (( media_reference == 0 )) || fail 'A process references a media source tree'
    (( scan_error == 0 )) || fail 'The /proc process-reference scan was incomplete; refusing to migrate'
    printf '%s\n' 'Validated /proc: no process references either source tree.'
}

normalize_source_tree() {
    local source=$1

    if ! find -P "$source" -xdev -type d \
        -exec chgrp "$SHARED_GID" -- {} + \
        -exec chmod g+rws -- {} +; then
        fail "Unable to normalize source-tree directories: $source"
    fi
    if ! find -P "$source" -xdev -type f \
        -exec chgrp "$SHARED_GID" -- {} + \
        -exec chmod g+rw -- {} +; then
        fail "Unable to normalize source-tree regular files: $source"
    fi
    if ! find -P "$source" -xdev -type l \
        -exec chgrp -h "$SHARED_GID" -- {} +; then
        fail "Unable to normalize source-tree symlinks: $source"
    fi
    if ! chown "root:${SHARED_GID}" -- "$source" || ! chmod 2775 -- "$source"; then
        fail "Unable to set exact metadata on source root: $source"
    fi
}

verify_recursive_contract() {
    local source=$1
    local bad_directory bad_file bad_symlink

    verify_exact_root_metadata "$source"
    bad_directory=$(find -P "$source" -xdev -type d \
        \( ! -group "$SHARED_GID" -o ! -perm -2070 \) -print -quit)
    bad_file=$(find -P "$source" -xdev -type f \
        \( ! -group "$SHARED_GID" -o ! -perm -0060 \) -print -quit)
    bad_symlink=$(find -P "$source" -xdev -type l \
        ! -group "$SHARED_GID" -print -quit)
    if [[ -n "$bad_directory" || -n "$bad_file" || -n "$bad_symlink" ]]; then
        fail "Shared-group contract failed below $source: directory=${bad_directory:-none} file=${bad_file:-none} symlink=${bad_symlink:-none}"
    fi
}

count_tree_entries() {
    local source=$1
    local directories files symlinks

    directories=$(find -P "$source" -xdev -type d -printf x | wc -c) || return 1
    files=$(find -P "$source" -xdev -type f -printf x | wc -c) || return 1
    symlinks=$(find -P "$source" -xdev -type l -printf x | wc -c) || return 1
    printf '  %s: directories=%s regular-files=%s symlinks=%s\n' \
        "$source" "$directories" "$files" "$symlinks"
}

recreate_empty_destination() {
    local destination=$1
    local unexpected

    if [[ -L "$destination" || ( -e "$destination" && ! -d "$destination" ) ]]; then
        printf 'Rollback cannot recreate destination; wrong file type: %s\n' \
            "$destination" >&2
        return 1
    fi
    if [[ -d "$destination" ]]; then
        if ! unexpected=$(find -P "$destination" -mindepth 1 -maxdepth 1 \
            -print -quit); then
            printf 'Rollback cannot inspect destination: %s\n' "$destination" >&2
            return 1
        fi
        if [[ -n "$unexpected" ]]; then
            printf 'Rollback refuses to remove unexpected destination content: %s (first=%s)\n' \
                "$destination" "$unexpected" >&2
            return 1
        fi
    else
        if ! install -d -- "$destination"; then
            printf 'Rollback cannot recreate destination: %s\n' "$destination" >&2
            return 1
        fi
    fi
    if ! chown "root:${SHARED_GID}" -- "$destination" || \
        ! chmod 2775 -- "$destination"; then
        printf 'Rollback cannot restore destination metadata: %s\n' "$destination" >&2
        return 1
    fi
    if [[ "$(stat -c '%u:%g %a' -- "$destination")" != "0:${SHARED_GID} 2775" ]]; then
        printf 'Rollback restored unexpected destination metadata: %s\n' "$destination" >&2
        return 1
    fi
}

rollback_move() {
    local destination=$1
    local source=$2
    local expected_identity=$3

    if [[ -e "$source" || -L "$source" ]]; then
        printf 'Rollback refuses to overwrite an existing source path: %s\n' "$source" >&2
        return 1
    fi
    if [[ -L "$destination" || ! -d "$destination" ]]; then
        printf 'Rollback cannot find the completed destination directory: %s\n' \
            "$destination" >&2
        return 1
    fi
    if [[ "$(stat -c '%d:%i' -- "$destination")" != "$expected_identity" ]]; then
        printf 'Rollback refuses an unexpected destination identity: %s\n' \
            "$destination" >&2
        return 1
    fi
    if ! mv --no-copy -T -- "$destination" "$source"; then
        printf 'Rollback could not move %s back to %s\n' "$destination" "$source" >&2
        return 1
    fi
    if [[ ! -d "$source" || -e "$destination" || -L "$destination" || \
        "$(stat -c '%d:%i' -- "$source")" != "$expected_identity" ]]; then
        printf 'Rollback move verification failed: %s -> %s\n' "$destination" "$source" >&2
        return 1
    fi
}

first_renamed=0
second_renamed=0
movies_destination_removed=0
tv_destination_removed=0
rename_stage_active=0

reconcile_rename_state() {
    local state_error=0

    if (( movies_destination_removed )); then
        if [[ ! -e "$SOURCE_MOVIES" && ! -L "$SOURCE_MOVIES" && \
            -d "$DEST_MOVIES" && ! -L "$DEST_MOVIES" ]]; then
            first_renamed=1
        elif [[ -d "$SOURCE_MOVIES" && ! -L "$SOURCE_MOVIES" && \
            ! -e "$DEST_MOVIES" && ! -L "$DEST_MOVIES" ]]; then
            first_renamed=0
        else
            printf 'Rollback cannot classify the movies rename state: source=%s destination=%s\n' \
                "$SOURCE_MOVIES" "$DEST_MOVIES" >&2
            state_error=1
        fi
    fi
    if (( tv_destination_removed )); then
        if [[ ! -e "$SOURCE_TV" && ! -L "$SOURCE_TV" && \
            -d "$DEST_TV" && ! -L "$DEST_TV" ]]; then
            second_renamed=1
        elif [[ -d "$SOURCE_TV" && ! -L "$SOURCE_TV" && \
            ! -e "$DEST_TV" && ! -L "$DEST_TV" ]]; then
            second_renamed=0
        else
            printf 'Rollback cannot classify the tv rename state: source=%s destination=%s\n' \
                "$SOURCE_TV" "$DEST_TV" >&2
            state_error=1
        fi
    fi
    return "$state_error"
}

rollback_changes() {
    local rollback_ok=0

    if ! reconcile_rename_state; then
        rollback_ok=1
    fi
    if (( second_renamed )); then
        if rollback_move "$DEST_TV" "$SOURCE_TV" "$tv_identity"; then
            second_renamed=0
        else
            rollback_ok=1
        fi
    fi
    if (( first_renamed )); then
        if rollback_move "$DEST_MOVIES" "$SOURCE_MOVIES" "$movies_identity"; then
            first_renamed=0
        else
            rollback_ok=1
        fi
    fi
    if ! recreate_empty_destination "$DEST_MOVIES"; then
        rollback_ok=1
    fi
    if ! recreate_empty_destination "$DEST_TV"; then
        rollback_ok=1
    fi
    return "$rollback_ok"
}

rename_stage_exit() {
    local status=$?

    if (( rename_stage_active )); then
        trap - EXIT
        printf 'Rename stage did not complete; attempting rollback.\n' >&2
        if rollback_changes; then
            printf '%s\n' 'ROLLBACK SUCCESS: completed renames were moved back and empty destinations restored.' >&2
        else
            printf '%s\n' 'ROLLBACK FAILURE: inspect both source and destination paths before any manual action.' >&2
            status=1
        fi
        exit "$status"
    fi
}
trap rename_stage_exit EXIT

verify_exact_media_mount
for path in "${required_paths[@]}"; do
    verify_required_root "$path"
done
printf 'Validated all Phase-2 required roots: count=%s\n' "${#required_paths[@]}"

movies_source_missing=0
tv_source_missing=0
[[ -e "$SOURCE_MOVIES" || -L "$SOURCE_MOVIES" ]] || movies_source_missing=1
[[ -e "$SOURCE_TV" || -L "$SOURCE_TV" ]] || tv_source_missing=1
if (( movies_source_missing && tv_source_missing )); then
    for destination in "${destination_paths[@]}"; do
        verify_mount_source_and_device "$destination"
        verify_source_tree_types "$destination"
        verify_recursive_contract "$destination"
        if [[ -z "$(find -P "$destination" -xdev -type f -print -quit)" ]]; then
            fail "Cannot recognize an already-completed migration without a regular file: $destination"
        fi
    done
    printf '%s\n' 'Migration was already complete: old paths are absent and both populated destinations satisfy the shared-group contract.'
    printf '%s\n' 'No filesystem changes were made by this rerun.'
    exit 0
fi
if (( movies_source_missing || tv_source_missing )); then
    fail 'Inconsistent partial migration state; return the output and inspect both source/destination pairs before acting'
fi

for source in "${source_paths[@]}"; do
    require_real_directory "$source"
    verify_mount_source_and_device "$source"
    verify_source_tree_types "$source"
done
for destination in "${destination_paths[@]}"; do
    verify_empty_destination "$destination"
done
verify_jellyfin_stopped
scan_media_process_references

printf '%s\n' 'Normalizing source-tree shared-group metadata before any rename.'
for source in "${source_paths[@]}"; do
    normalize_source_tree "$source"
    verify_recursive_contract "$source"
done
printf '%s\n' 'Verified recursive shared-group contract before renames.'

movies_identity=$(stat -c '%d:%i' -- "$SOURCE_MOVIES")
tv_identity=$(stat -c '%d:%i' -- "$SOURCE_TV")
printf 'Captured source identities: movies=%s tv=%s\n' "$movies_identity" "$tv_identity"

# Metadata normalization can take long enough for state to change. Recheck
# both known-service and open-writer evidence immediately before renaming.
verify_jellyfin_stopped
scan_media_process_references

rename_stage_active=1
if ! rmdir -- "$DEST_MOVIES"; then
    fail "Unable to remove the verified-empty destination: $DEST_MOVIES"
fi
movies_destination_removed=1
if ! rmdir -- "$DEST_TV"; then
    fail "Unable to remove the verified-empty destination: $DEST_TV"
fi
tv_destination_removed=1

if ! mv --no-copy -T -- "$SOURCE_MOVIES" "$DEST_MOVIES"; then
    if [[ ! -e "$SOURCE_MOVIES" && -d "$DEST_MOVIES" ]]; then
        first_renamed=1
    fi
    fail "First library rename failed: $SOURCE_MOVIES -> $DEST_MOVIES"
fi
first_renamed=1
if [[ -e "$SOURCE_MOVIES" || -L "$SOURCE_MOVIES" || ! -d "$DEST_MOVIES" || \
    "$(stat -c '%d:%i' -- "$DEST_MOVIES")" != "$movies_identity" ]]; then
    fail "First rename-stage verification failed"
fi

if ! mv --no-copy -T -- "$SOURCE_TV" "$DEST_TV"; then
    if [[ ! -e "$SOURCE_TV" && -d "$DEST_TV" ]]; then
        second_renamed=1
    fi
    fail "Second library rename failed: $SOURCE_TV -> $DEST_TV"
fi
second_renamed=1
if [[ -e "$SOURCE_TV" || -L "$SOURCE_TV" || ! -d "$DEST_TV" || \
    "$(stat -c '%d:%i' -- "$DEST_TV")" != "$tv_identity" ]]; then
    fail "Second rename-stage verification failed"
fi

verify_exact_media_mount
for path in "${required_paths[@]}"; do
    verify_required_root "$path"
done
for destination in "${destination_paths[@]}"; do
    require_real_directory "$destination"
    verify_mount_source_and_device "$destination"
done
if [[ -e "$SOURCE_MOVIES" || -L "$SOURCE_MOVIES" || -e "$SOURCE_TV" || -L "$SOURCE_TV" ]]; then
    fail 'An old source path still exists after the renames'
fi
if [[ "$(stat -c '%d:%i' -- "$DEST_MOVIES")" != "$movies_identity" || \
    "$(stat -c '%d:%i' -- "$DEST_TV")" != "$tv_identity" ]]; then
    fail 'Destination identity does not match the captured source identity'
fi
verify_recursive_contract "$DEST_MOVIES"
verify_recursive_contract "$DEST_TV"

rename_stage_active=0
printf '%s\n' 'Migration succeeded: old source paths are absent and destinations retain captured identities.'
printf '%s\n' 'Final library counts:'
for destination in "${destination_paths[@]}"; do
    if ! count_tree_entries "$destination"; then
        printf 'WARNING: migration is complete, but final counts failed for %s\n' \
            "$destination" >&2
    fi
    if final_metadata=$(stat -c '%u:%g %a %d:%i' -- "$destination"); then
        printf 'Final root: %s %s\n' "$final_metadata" "$destination"
    else
        printf 'WARNING: migration is complete, but final stat failed for %s\n' \
            "$destination" >&2
    fi
done
printf '%s\n' 'No SELinux relabel, deployment, media deletion, or Jellyfin restart was performed.'
