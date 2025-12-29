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

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@24-hours-ago" \
        && zfs destroy "$DATASET@24-hours-ago" 
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@23-hours-ago" \
        && zfs rename "$DATASET@23-hours-ago" "$DATASET@24-hours-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@22-hours-ago" \
        && zfs rename "$DATASET@22-hours-ago" "$DATASET@23-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@21-hours-ago" \
        && zfs rename "$DATASET@21-hours-ago" "$DATASET@22-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@20-hours-ago" \
        && zfs rename "$DATASET@20-hours-ago" "$DATASET@21-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@19-hours-ago" \
        && zfs rename "$DATASET@19-hours-ago" "$DATASET@20-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@18-hours-ago" \
        && zfs rename "$DATASET@18-hours-ago" "$DATASET@19-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@17-hours-ago" \
        && zfs rename "$DATASET@17-hours-ago" "$DATASET@18-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@16-hours-ago" \
        && zfs rename "$DATASET@16-hours-ago" "$DATASET@17-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@15-hours-ago" \
        && zfs rename "$DATASET@15-hours-ago" "$DATASET@16-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@14-hours-ago" \
        && zfs rename "$DATASET@14-hours-ago" "$DATASET@15-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@13-hours-ago" \
        && zfs rename "$DATASET@13-hours-ago" "$DATASET@14-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@12-hours-ago" \
        && zfs rename "$DATASET@12-hours-ago" "$DATASET@13-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@11-hours-ago" \
        && zfs rename "$DATASET@11-hours-ago" "$DATASET@12-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@10-hours-ago" \
        && zfs rename "$DATASET@10-hours-ago" "$DATASET@11-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@9-hours-ago" \
        && zfs rename "$DATASET@9-hours-ago" "$DATASET@10-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@8-hours-ago" \
        && zfs rename "$DATASET@8-hours-ago" "$DATASET@9-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@7-hours-ago" \
        && zfs rename "$DATASET@7-hours-ago" "$DATASET@8-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@6-hours-ago" \
        && zfs rename "$DATASET@6-hours-ago" "$DATASET@7-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@5-hours-ago" \
        && zfs rename "$DATASET@5-hours-ago" "$DATASET@6-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@4-hours-ago" \
        && zfs rename "$DATASET@4-hours-ago" "$DATASET@5-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@3-hours-ago" \
        && zfs rename "$DATASET@3-hours-ago" "$DATASET@4-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@2-hours-ago" \
        && zfs rename "$DATASET@2-hours-ago" "$DATASET@3-hours-ago"

    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@1-hour-ago" \
        && zfs rename "$DATASET@1-hour-ago" "$DATASET@2-hours-ago"
    
    echo "$EXISTING_SNAPSHOTS" | grep "$DATASET@0-hours-ago" \
        && zfs rename "$DATASET@0-hours-ago" "$DATASET@1-hour-ago"

    zfs snapshot "$DATASET@0-hours-ago"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
