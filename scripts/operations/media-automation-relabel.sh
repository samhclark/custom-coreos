#!/usr/bin/env bash
# ABOUTME: Applies and verifies the bounded SELinux label for media automation.
# ABOUTME: This phase never changes media contents, ownership, modes, or paths.

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

destination_paths=("$DEST_MOVIES" "$DEST_TV")

declare root_device=""
declare -A before_identity=()
declare -A before_counts=()
declare -A before_metadata=()
declare temp_directory=""
declare before_scope_file=""
declare before_scope_digest=""

if ((EUID != 0)); then
    printf 'Run this operation as root: sudo bash %q\n' "$0" >&2
    exit 1
fi

for command in findmnt find getenforce matchpathcon mktemp pgrep rm restorecon sha256sum stat systemctl wc; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

fail() {
    printf 'ABORTED: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [[ -n "$temp_directory" && -d "$temp_directory" ]]; then
        rm -rf -- "$temp_directory"
    fi
}
trap cleanup EXIT

require_real_directory() {
    local path=$1

    if [[ -L "$path" || ! -d "$path" ]]; then
        fail "Required real directory is missing or is a symlink: $path"
    fi
}

verify_exact_media_mount() {
    local mount_record root_mount_target root_mount_source mount_target
    local nested_mounts

    require_real_directory "$ROOT"
    if ! mount_record=$(findmnt -n -o TARGET,SOURCE --mountpoint "$ROOT"); then
        fail "Unable to find the exact mount at $ROOT"
    fi
    read -r root_mount_target root_mount_source <<< "$mount_record"
    if [[ "$root_mount_target" != "$ROOT" || "$root_mount_source" != "$EXPECTED_SOURCE" ]]; then
        fail "Expected exact mount $ROOT from $EXPECTED_SOURCE; found target=$root_mount_target source=$root_mount_source"
    fi

    root_device=$(stat -c '%d' -- "$ROOT")
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

verify_on_media_dataset() {
    local path=$1
    local source device

    source=$(findmnt -n -o SOURCE -T "$path") || fail "Unable to inspect mount source: $path"
    [[ "$source" == "$EXPECTED_SOURCE" ]] ||
        fail "$path is mounted from $source, expected $EXPECTED_SOURCE"
    device=$(stat -c '%d' -- "$path")
    [[ "$device" == "$root_device" ]] ||
        fail "$path is on device $device, expected $root_device"
}

verify_exact_root_metadata() {
    local path=$1
    local metadata

    metadata=$(stat -c '%u:%g %a' -- "$path")
    [[ "$metadata" == "0:${SHARED_GID} 2775" ]] ||
        fail "Unexpected required-root metadata: $path (found=$metadata expected=0:${SHARED_GID} 2775)"
}

verify_required_roots() {
    local path

    for path in "${required_paths[@]}"; do
        require_real_directory "$path"
        verify_on_media_dataset "$path"
        verify_exact_root_metadata "$path"
    done
    printf 'Validated all required roots: count=%s owner=root:%s mode=2775 device=%s\n' \
        "${#required_paths[@]}" "$SHARED_GID" "$root_device"
}

verify_old_paths_absent() {
    if [[ -e "$SOURCE_MOVIES" || -L "$SOURCE_MOVIES" || \
        -e "$SOURCE_TV" || -L "$SOURCE_TV" ]]; then
        fail "An old media path still exists: ${SOURCE_MOVIES} or ${SOURCE_TV}"
    fi
    printf 'Validated old library paths absent: %s and %s\n' "$SOURCE_MOVIES" "$SOURCE_TV"
}

verify_destination_tree_types() {
    local path=$1
    local unexpected

    if ! unexpected=$(find -P "$path" -xdev \
        ! \( -type d -o -type f -o -type l \) -print -quit); then
        fail "Unable to inspect destination entry types: $path"
    fi
    [[ -z "$unexpected" ]] || fail "Unsupported destination entry type: $unexpected"
}

verify_populated_destination() {
    local path=$1
    local first_entry first_file

    require_real_directory "$path"
    verify_on_media_dataset "$path"
    if ! first_entry=$(find -P "$path" -xdev \
        -mindepth 1 -print -quit); then
        fail "Unable to inspect destination: $path"
    fi
    [[ -n "$first_entry" ]] || fail "Destination library is empty: $path"
    if ! first_file=$(find -P "$path" -xdev -type f -print -quit); then
        fail "Unable to inspect destination regular files: $path"
    fi
    [[ -n "$first_file" ]] || fail "Destination library has no regular files: $path"
    verify_destination_tree_types "$path"
}

verify_jellyfin_stopped() {
    local manager_state remaining_processes pgrep_status

    if ! manager_state=$(systemctl show --property=ActiveState --value \
        "$JELLYFIN_MANAGER"); then
        fail "Unable to inspect $JELLYFIN_MANAGER"
    fi
    [[ "$manager_state" == inactive ]] ||
        fail "Refusing to relabel while $JELLYFIN_MANAGER is $manager_state"

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

verify_selinux_enforcing() {
    local mode

    mode=$(getenforce) || fail 'Unable to read SELinux enforcement mode'
    [[ "$mode" == Enforcing ]] ||
        fail "SELinux must be Enforcing before relabeling; found $mode"
    printf 'Validated SELinux mode: %s\n' "$mode"
}

label_is_exact() {
    local label=$1

    [[ "$label" == *:object_r:container_file_t:s0 ]]
}

verify_policy_label() {
    local path=$1
    local expected

    if ! expected=$(matchpathcon -n "$path"); then
        fail "Unable to read deployed SELinux policy for $path"
    fi
    label_is_exact "$expected" ||
        fail "Deployed SELinux policy does not assign container_file_t:s0 to $path: $expected"
}

verify_policy_labels_before_mutation() {
    local path checked=0

    while IFS= read -r -d '' path; do
        verify_policy_label "$path"
        checked=$((checked + 1))
    done < "$before_scope_file"
    ((checked > 0)) || fail 'The relabel scope is unexpectedly empty'
    printf 'Validated deployed SELinux policy recursively: %s paths assign container_file_t:s0\n' \
        "$checked"
}

prepare_relabel_scope() {
    local unexpected_top_level

    if [[ ! -d /run || -L /run ]]; then
        fail '/run must be a real directory for temporary verification evidence'
    fi
    if ! unexpected_top_level=$(find -P "$ROOT" -xdev -mindepth 1 -maxdepth 1 \
        ! -name data ! -name .zfs -print -quit); then
        fail 'Unable to inspect top-level media dataset entries'
    fi
    [[ -z "$unexpected_top_level" ]] ||
        fail "Unexpected top-level media dataset entry: $unexpected_top_level"
    if [[ -e "$ROOT/.zfs" || -L "$ROOT/.zfs" ]]; then
        [[ -d "$ROOT/.zfs" && ! -L "$ROOT/.zfs" ]] ||
            fail "The ZFS control path is not a real directory: $ROOT/.zfs"
    fi

    temp_directory=$(mktemp -d /run/media-automation-relabel.XXXXXX) ||
        fail 'Unable to create temporary verification directory under /run'
    before_scope_file="$temp_directory/before-paths"
    if ! find -P "$ROOT" -xdev \
        -path "$ROOT/.zfs" -prune -o -print0 > "$before_scope_file"; then
        fail 'Unable to enumerate the bounded relabel scope'
    fi
    before_scope_digest=$(sha256sum "$before_scope_file") ||
        fail 'Unable to hash the bounded relabel scope'
    before_scope_digest=${before_scope_digest%% *}
}

count_tree_entries() {
    local path=$1
    local directories files symlinks

    directories=$(find -P "$path" -xdev -type d -printf x | wc -c) || return 1
    files=$(find -P "$path" -xdev -type f -printf x | wc -c) || return 1
    symlinks=$(find -P "$path" -xdev -type l -printf x | wc -c) || return 1
    printf '%s:%s:%s' "$directories" "$files" "$symlinks"
}

capture_before_state() {
    local path count

    for path in "${required_paths[@]}"; do
        before_metadata["$path"]=$(stat -c '%u:%g %a' -- "$path")
    done
    for path in "${destination_paths[@]}"; do
        before_identity["$path"]=$(stat -c '%d:%i' -- "$path")
        if ! count=$(count_tree_entries "$path"); then
            fail "Unable to count destination entries: $path"
        fi
        before_counts["$path"]=$count
        printf 'Captured destination: %s identity=%s entries=%s metadata=%s\n' \
            "$path" "${before_identity[$path]}" "$count" "${before_metadata[$path]}"
    done
}

verify_recursive_group_contract() {
    local bad_directory bad_file bad_symlink
    local search_root="$ROOT/data"

    if ! bad_directory=$(find -P "$search_root" -xdev -type d \
        \( ! -group "$SHARED_GID" -o ! -perm -2070 -o ! -perm -0010 \) \
        -print -quit); then
        fail "Unable to inspect recursive directory group contract"
    fi
    if ! bad_file=$(find -P "$search_root" -xdev -type f \
        \( ! -group "$SHARED_GID" -o ! -perm -0060 \) -print -quit); then
        fail "Unable to inspect recursive file group contract"
    fi
    if ! bad_symlink=$(find -P "$search_root" -xdev -type l \
        ! -group "$SHARED_GID" -print -quit); then
        fail "Unable to inspect recursive symlink group contract"
    fi
    if [[ -n "$bad_directory" || -n "$bad_file" || -n "$bad_symlink" ]]; then
        fail "Recursive shared-group contract failed: directory=${bad_directory:-none} file=${bad_file:-none} symlink=${bad_symlink:-none}"
    fi
    printf 'Validated recursive shared-group contract under %s: group=%s directories=setgid+g+rwx files=g+rw\n' \
        "$search_root" "$SHARED_GID"
}

verify_actual_labels() {
    local label path checked=0
    local after_scope_file="$temp_directory/after-paths"
    local after_scope_digest

    if ! find -P "$ROOT" -xdev \
        -path "$ROOT/.zfs" -prune -o -print0 > "$after_scope_file"; then
        fail 'Unable to re-enumerate the bounded relabel scope'
    fi
    after_scope_digest=$(sha256sum "$after_scope_file") ||
        fail 'Unable to hash the post-relabel path set'
    after_scope_digest=${after_scope_digest%% *}
    if [[ "$before_scope_digest" != "$after_scope_digest" ]]; then
        fail 'The relabel path set changed during the operation'
    fi
    while IFS= read -r -d '' path; do
        if ! label=$(stat -c '%C' -- "$path"); then
            fail "Unable to read SELinux label: $path"
        fi
        label_is_exact "$label" ||
            fail "Unexpected actual SELinux label: $path: $label"
        checked=$((checked + 1))
    done < "$after_scope_file"
    printf 'Validated actual SELinux labels recursively: all %s relabeled paths use container_file_t:s0\n' \
        "$checked"
}

verify_after_state() {
    local path identity count metadata

    verify_exact_media_mount
    verify_required_roots
    verify_old_paths_absent
    for path in "${destination_paths[@]}"; do
        verify_populated_destination "$path"
        identity=$(stat -c '%d:%i' -- "$path")
        [[ "$identity" == "${before_identity[$path]}" ]] ||
            fail "Destination identity changed: $path (before=${before_identity[$path]} after=$identity)"
        if ! count=$(count_tree_entries "$path"); then
            fail "Unable to recount destination entries: $path"
        fi
        [[ "$count" == "${before_counts[$path]}" ]] ||
            fail "Destination entry count changed: $path (before=${before_counts[$path]} after=$count)"
        printf 'Verified unchanged destination: %s identity=%s entries=%s\n' \
            "$path" "$identity" "$count"
    done
    for path in "${required_paths[@]}"; do
        metadata=$(stat -c '%u:%g %a' -- "$path")
        [[ "$metadata" == "${before_metadata[$path]}" ]] ||
            fail "Required-root ownership/mode changed: $path (before=${before_metadata[$path]} after=$metadata)"
    done
    verify_recursive_group_contract
    verify_jellyfin_stopped
}

verify_exact_media_mount
verify_required_roots
verify_old_paths_absent
for path in "${destination_paths[@]}"; do
    verify_populated_destination "$path"
done
verify_jellyfin_stopped
verify_selinux_enforcing
prepare_relabel_scope
verify_policy_labels_before_mutation
capture_before_state

restorecon_arguments=(-F -R -x)
if [[ -d "$ROOT/.zfs" ]]; then
    restorecon_arguments+=(-e "$ROOT/.zfs")
    printf 'Visible ZFS snapshot control directory excluded: %s\n' "$ROOT/.zfs"
fi
printf 'Applying bounded SELinux relabel under %s.\n' "$ROOT"
restorecon "${restorecon_arguments[@]}" "$ROOT" ||
    fail "Unable to restore SELinux labels under $ROOT"

verify_actual_labels
verify_after_state
printf '%s\n' 'Relabel succeeded. No media contents, paths, ownership, modes, deployments, or Jellyfin state were changed.'
