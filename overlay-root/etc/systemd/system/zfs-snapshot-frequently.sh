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

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@60-minutes-ago" \
        && zfs destroy "$DATASET@60-minutes-ago" 
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@45-minutes-ago" \
        && zfs rename "$DATASET@45-minutes-ago" "$DATASET@60-minutes-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@30-minutes-ago" \
        && zfs rename "$DATASET@30-minutes-ago" "$DATASET@45-minutes-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@15-minutes-ago" \
        && zfs rename "$DATASET@15-minutes-ago" "$DATASET@30-minutes-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@00-minutes-ago" \
        && zfs rename "$DATASET@00-minutes-ago" "$DATASET@15-minutes-ago"

    zfs snapshot "$DATASET@00-minutes-ago"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
