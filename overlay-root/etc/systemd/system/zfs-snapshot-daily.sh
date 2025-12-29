#!/bin/sh 

# This is written to be run as a systemd unit.
# More specifically, an instance of a systemd template. 
# That means, this will be called with an instance identifier, 
# which can be referenced with `%i` in the unit file.

set -eu

DATASET="tank/$1"
alias zfs="/usr/sbin/zfs"
alias grep="/usr/bin/grep --quiet  --line-regexp --fixed-string"

main() {
    EXISTING_SNAPSHOTS=$(zfs list -H -o name -t snapshot)

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@7-days-ago" \
        && zfs destroy "$DATASET@7-days-ago" 

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@6-days-ago" \
        && zfs rename "$DATASET@6-days-ago" "$DATASET@7-days-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@5-days-ago" \
        && zfs rename "$DATASET@5-days-ago" "$DATASET@6-days-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@4-days-ago" \
        && zfs rename "$DATASET@4-days-ago" "$DATASET@5-days-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@3-days-ago" \
        && zfs rename "$DATASET@3-days-ago" "$DATASET@4-days-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@2-days-ago" \
        && zfs rename "$DATASET@2-days-ago" "$DATASET@3-days-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@yesterday" \
        && zfs rename "$DATASET@yesterday" "$DATASET@2-days-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@today" \
        && zfs rename "$DATASET@today" "$DATASET@yesterday"

    zfs snapshot "$DATASET@today"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
