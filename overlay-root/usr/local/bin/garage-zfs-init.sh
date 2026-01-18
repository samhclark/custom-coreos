#!/bin/bash
# Initialize ZFS datasets for Garage object storage
set -euo pipefail

POOL="tank"
META_DATASET="${POOL}/garage-meta"
DATA_DATASET="${POOL}/garage-data"

echo "Initializing ZFS datasets for Garage..."

# Check if datasets already exist
if zfs list "${META_DATASET}" &>/dev/null; then
    echo "Metadata dataset ${META_DATASET} already exists, skipping..."
else
    echo "Creating metadata dataset: ${META_DATASET}"
    zfs create \
        -o recordsize=16K \
        -o compression=lz4 \
        -o atime=off \
        -o xattr=sa \
        -o mountpoint=/var/lib/garage/meta \
        "${META_DATASET}"
    echo "Metadata dataset created successfully"
fi

if zfs list "${DATA_DATASET}" &>/dev/null; then
    echo "Data dataset ${DATA_DATASET} already exists, skipping..."
else
    echo "Creating data dataset: ${DATA_DATASET}"
    zfs create \
        -o recordsize=1M \
        -o compression=off \
        -o atime=off \
        -o xattr=sa \
        -o mountpoint=/var/lib/garage/data \
        "${DATA_DATASET}"
    echo "Data dataset created successfully"
fi

# Set permissions
mkdir -p /var/lib/garage/meta /var/lib/garage/data
chown -R root:root /var/lib/garage
chmod -R 755 /var/lib/garage

echo "ZFS datasets for Garage initialized successfully"
