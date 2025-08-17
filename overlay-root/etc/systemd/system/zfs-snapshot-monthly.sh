#!/bin/sh 

# This is written to be run as a systemd unit.
# More specifically, an instance of a systemd template. 
# That means, this will be called with an instance identifier, 
# which can be referenced with `%i`

set -eu

DATASET="$1"
alias zfs="/usr/sbin/zfs"
alias grep="/usr/bin/grep --quiet  --line-regexp --fixed-string"

main() {
    EXISTING_SNAPSHOTS=$(zfs list -H -o name -t snapshot)

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@12-months-ago" \
        && zfs destroy "$DATASET@12-months-ago" 

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@11-months-ago" \
        && zfs rename "$DATASET@11-months-ago" "$DATASET@12-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@10-months-ago" \
        && zfs rename "$DATASET@10-months-ago" "$DATASET@11-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@9-months-ago" \
        && zfs rename "$DATASET@9-months-ago" "$DATASET@10-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@8-months-ago" \
        && zfs rename "$DATASET@8-months-ago" "$DATASET@9-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@7-months-ago" \
        && zfs rename "$DATASET@7-months-ago" "$DATASET@8-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@6-months-ago" \
        && zfs rename "$DATASET@6-months-ago" "$DATASET@7-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@5-months-ago" \
        && zfs rename "$DATASET@5-months-ago" "$DATASET@6-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@4-months-ago" \
        && zfs rename "$DATASET@4-months-ago" "$DATASET@5-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@3-months-ago" \
        && zfs rename "$DATASET@3-months-ago" "$DATASET@4-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@2-months-ago" \
        && zfs rename "$DATASET@2-months-ago" "$DATASET@3-months-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@last-month" \
        && zfs rename "$DATASET@last-month" "$DATASET@2-months-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@this-month" \
        && zfs rename "$DATASET@this-month" "$DATASET@last-month"

    zfs snapshot "$DATASET@this-month"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
