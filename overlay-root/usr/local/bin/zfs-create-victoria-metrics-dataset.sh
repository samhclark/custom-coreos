#!/bin/bash
# Creates ZFS datasets for VictoriaMetrics time series storage
#
# This script is idempotent - it only creates datasets that don't exist.
#
# VictoriaMetrics stores time-series data with sequential writes and
# background merge compactions. Data compresses well with lz4.

set -euo pipefail

POOL="tank"
BASE_DATASET="${POOL}/victoria-metrics"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

dataset_exists() {
    zfs list -H -o name "$1" &>/dev/null
}

# Check if pool exists
if ! zpool list -H -o name | grep -q "^${POOL}$"; then
    log "ERROR: Pool '${POOL}' does not exist"
    exit 1
fi

# Create parent dataset (not mounted - just a container for child datasets)
if dataset_exists "${BASE_DATASET}"; then
    log "Dataset ${BASE_DATASET} already exists, skipping"
else
    log "Creating ${BASE_DATASET} (unmounted parent)"
    zfs create -o mountpoint=none "${BASE_DATASET}"
fi

# Create data dataset - optimized for time-series workload
# - recordsize=128K: default VictoriaMetrics block size
# - compression=lz4: time-series data compresses well, lz4 is fast
# - atime=off: no need to track access times
if dataset_exists "${BASE_DATASET}/data"; then
    log "Dataset ${BASE_DATASET}/data already exists, skipping"
else
    log "Creating ${BASE_DATASET}/data (optimized for time-series storage)"
    zfs create \
        -o mountpoint=/var/lib/victoria-metrics \
        -o recordsize=128K \
        -o compression=lz4 \
        -o atime=off \
        "${BASE_DATASET}/data"
    semanage fcontext -a -t container_file_t "/var/lib/victoria-metrics(/.*)?"
    restorecon -R /var/lib/victoria-metrics
fi

log "VictoriaMetrics ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${BASE_DATASET}/data"
