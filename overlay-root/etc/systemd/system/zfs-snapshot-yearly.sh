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
    NOW=$(date --utc --iso-8601=date)
    zfs snapshot "$DATASET@$NOW"
}

if zfs list -H -o name | grep "$DATASET"; then
    main
else
    echo "No such dataset $DATASET"
    exit 1
fi
