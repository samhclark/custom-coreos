#!/usr/bin/env bash
# ABOUTME: Stops Jellyfin before the media-automation storage migration.

set -euo pipefail

export LC_ALL=C

JELLYFIN_USER=_nas_jellyfin
JELLYFIN_UID=51120
JELLYFIN_HOME=/var/home/_nas_jellyfin
USER_MANAGER="user@${JELLYFIN_UID}.service"
RUNTIME_DIRECTORY="/run/user/${JELLYFIN_UID}"

if ((EUID != 0)); then
    printf 'Run this operation as root: sudo bash %q\n' "$0" >&2
    exit 1
fi

for command in cut getent pgrep runuser systemctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

account_record=$(getent passwd "$JELLYFIN_USER" || true)
account_uid=$(cut -d: -f3 <<< "$account_record")
account_home=$(cut -d: -f6 <<< "$account_record")
if [[ "$account_uid" != "$JELLYFIN_UID" || "$account_home" != "$JELLYFIN_HOME" ]]; then
    printf 'Expected %s to have UID %s and home %s; found UID %s and home %s\n' \
        "$JELLYFIN_USER" "$JELLYFIN_UID" "$JELLYFIN_HOME" \
        "${account_uid:-no account}" "${account_home:-no account}" >&2
    exit 1
fi
printf 'Validated account: %s UID=%s home=%s\n' \
    "$JELLYFIN_USER" "$account_uid" "$account_home"

printf '%s\n' 'Initial user-manager state:'
systemctl show "$USER_MANAGER" \
    --property=LoadState,ActiveState,SubState,Result --no-pager
manager_state=$(systemctl show --property=ActiveState --value "$USER_MANAGER")
case "$manager_state" in
    active)
        if [[ ! -S "$RUNTIME_DIRECTORY/bus" ]]; then
            printf 'The %s manager is active but its D-Bus socket is missing: %s/bus\n' \
                "$JELLYFIN_USER" "$RUNTIME_DIRECTORY" >&2
            exit 1
        fi

        printf '%s\n' 'Initial jellyfin.service state:'
        runuser -u "$JELLYFIN_USER" -- env \
            HOME="$JELLYFIN_HOME" \
            XDG_RUNTIME_DIR="$RUNTIME_DIRECTORY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIRECTORY}/bus" \
            systemctl --user show jellyfin.service \
                --property=LoadState,ActiveState,SubState,Result --no-pager

        printf 'Stopping jellyfin.service through the %s user manager.\n' \
            "$JELLYFIN_USER"
        runuser -u "$JELLYFIN_USER" -- env \
            HOME="$JELLYFIN_HOME" \
            XDG_RUNTIME_DIR="$RUNTIME_DIRECTORY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIRECTORY}/bus" \
            systemctl --user stop jellyfin.service
        ;;
    inactive | failed)
        printf '%s was already %s.\n' "$USER_MANAGER" "$manager_state"
        ;;
    *)
        printf 'Refusing to act while %s is %s.\n' \
            "$USER_MANAGER" "$manager_state" >&2
        exit 1
        ;;
esac

printf 'Stopping %s.\n' "$USER_MANAGER"
systemctl stop -- "$USER_MANAGER"

printf '%s\n' 'Final user-manager state:'
systemctl show "$USER_MANAGER" \
    --property=LoadState,ActiveState,SubState,Result --no-pager
manager_state=$(systemctl show --property=ActiveState --value "$USER_MANAGER")
if [[ "$manager_state" != inactive ]]; then
    printf 'Refusing to continue while %s is %s.\n' \
        "$USER_MANAGER" "$manager_state" >&2
    exit 1
fi

set +e
remaining_processes=$(pgrep -a -u "$JELLYFIN_UID" 2>&1)
pgrep_status=$?
set -e
case "$pgrep_status" in
    0)
        printf 'Processes still owned by UID %s:\n%s\n' \
            "$JELLYFIN_UID" "$remaining_processes" >&2
        exit 1
        ;;
    1)
        printf 'No processes remain for UID %s.\n' "$JELLYFIN_UID"
        ;;
    *)
        printf 'Unable to inspect processes for UID %s: %s\n' \
            "$JELLYFIN_UID" "$remaining_processes" >&2
        exit 1
        ;;
esac

printf '%s\n' 'Jellyfin is stopped. No media storage paths were changed.'
