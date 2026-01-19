#!/bin/bash
# Creates ZFS datasets for Garage object storage with optimized settings
#
# This script is idempotent - it only creates datasets that don't exist.
#
# Garage stores:
# - Metadata: SQLite database files (small random I/O, 4K pages)
# - Data: Object blocks (default 1MiB chunks, already zstd compressed)
#
# ZFS tuning strategy:
# - Metadata: small recordsize (4K) to match database page size, enable compression
# - Data: large recordsize (1M) to match Garage block_size, disable compression
#   (Garage already compresses with zstd, double compression wastes CPU)

set -euo pipefail

POOL="tank"
BASE_DATASET="${POOL}/garage"

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

# Create parent dataset
if dataset_exists "${BASE_DATASET}"; then
    log "Dataset ${BASE_DATASET} already exists, skipping"
else
    log "Creating ${BASE_DATASET}"
    zfs create -o mountpoint=/var/lib/garage "${BASE_DATASET}"
fi

# Create metadata dataset - optimized for small random I/O (SQLite)
# - recordsize=4K: matches SQLite page size, reduces write amplification
# - compression=lz4: metadata is compressible text/indexes, lz4 is fast
# - atime=off: no need to track access times
# - primarycache=metadata: hint for caching
if dataset_exists "${BASE_DATASET}/meta"; then
    log "Dataset ${BASE_DATASET}/meta already exists, skipping"
else
    log "Creating ${BASE_DATASET}/meta (optimized for database workload)"
    zfs create \
        -o mountpoint=/var/lib/garage/meta \
        -o recordsize=4K \
        -o compression=lz4 \
        -o atime=off \
        -o primarycache=metadata \
        "${BASE_DATASET}/meta"
fi

# Create data dataset - optimized for large sequential I/O (object blocks)
# - recordsize=1M: matches Garage's default block_size (1MiB)
# - compression=off: Garage already uses zstd compression, avoid double compression
# - atime=off: no need to track access times
if dataset_exists "${BASE_DATASET}/data"; then
    log "Dataset ${BASE_DATASET}/data already exists, skipping"
else
    log "Creating ${BASE_DATASET}/data (optimized for object storage)"
    zfs create \
        -o mountpoint=/var/lib/garage/data \
        -o recordsize=1M \
        -o compression=off \
        -o atime=off \
        "${BASE_DATASET}/data"
fi

log "Garage ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${BASE_DATASET}/meta" "${BASE_DATASET}/data"
