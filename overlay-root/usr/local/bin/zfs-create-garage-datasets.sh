#!/bin/bash
# Creates ZFS datasets for Garage object storage with optimized settings
#
# Garage stores:
# - Metadata: LMDB/SQLite database files (small random I/O, 4K pages)
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

# Check if pool exists
if ! zpool list -H -o name | grep -q "^${POOL}$"; then
    log "ERROR: Pool '${POOL}' does not exist"
    exit 1
fi

log "Creating Garage ZFS datasets..."

# Create parent dataset
log "Creating ${BASE_DATASET}"
zfs create -o mountpoint=/var/lib/garage "${BASE_DATASET}"

# Create metadata dataset - optimized for small random I/O (LMDB/SQLite)
# - recordsize=4K: matches LMDB page size, reduces write amplification
# - compression=lz4: metadata is compressible text/indexes, lz4 is fast
# - atime=off: no need to track access times
# - primarycache=metadata: hint for caching
log "Creating ${BASE_DATASET}/meta (optimized for database workload)"
zfs create \
    -o mountpoint=/var/lib/garage/meta \
    -o recordsize=4K \
    -o compression=lz4 \
    -o atime=off \
    -o primarycache=metadata \
    "${BASE_DATASET}/meta"

# Create data dataset - optimized for large sequential I/O (object blocks)
# - recordsize=1M: matches Garage's default block_size (1MiB)
# - compression=off: Garage already uses zstd compression, avoid double compression
# - atime=off: no need to track access times
log "Creating ${BASE_DATASET}/data (optimized for object storage)"
zfs create \
    -o mountpoint=/var/lib/garage/data \
    -o recordsize=1M \
    -o compression=off \
    -o atime=off \
    "${BASE_DATASET}/data"

log "Garage ZFS datasets created successfully"
log "Dataset properties:"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${BASE_DATASET}/meta" "${BASE_DATASET}/data"
