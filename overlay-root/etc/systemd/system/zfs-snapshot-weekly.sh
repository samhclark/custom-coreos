#!/bin/sh 

# This is written to be run as a systemd unit.
# More specifically, an instance of a systemd template. 
# That means, this will be called with an instance identifier, 
# which can be referenced with `%i`

set -eu

DATASET="tank/$1"
alias zfs="/usr/sbin/zfs"
alias grep="/usr/bin/grep --quiet  --line-regexp --fixed-string"

main() {
    EXISTING_SNAPSHOTS=$(zfs list -H -o name -t snapshot)

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@4-weeks-ago" \
        && zfs destroy "$DATASET@4-weeks-ago" 

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@3-weeks-ago" \
        && zfs rename "$DATASET@3-weeks-ago" "$DATASET@4-weeks-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@2-weeks-ago" \
        && zfs rename "$DATASET@2-weeks-ago" "$DATASET@3-weeks-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@last-week" \
        && zfs rename "$DATASET@last-week" "$DATASET@2-weeks-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@this-week" \
        && zfs rename "$DATASET@this-week" "$DATASET@last-week"

    zfs snapshot "$DATASET@this-week"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
