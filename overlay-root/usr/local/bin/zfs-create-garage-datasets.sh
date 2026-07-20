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
META_DATASET="${BASE_DATASET}/meta"
DATA_DATASET="${BASE_DATASET}/data"
META_PATH="/var/lib/garage/meta"
DATA_PATH="/var/lib/garage/data"
EXPECTED_LABEL="system_u:object_r:container_file_t:s0"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

dataset_exists() {
    zfs list -H -o name "$1" &>/dev/null
}

ensure_fcontext_rule() {
    local target="$1"

    if semanage fcontext -a -t container_file_t -r s0 "${target}" 2>/dev/null; then
        log "Added SELinux fcontext for ${target}"
        return
    fi

    semanage fcontext -m -t container_file_t -r s0 "${target}"
}

sample_descendant() {
    local path="$1"

    find "${path}" -xdev -mindepth 1 -maxdepth 1 \
        ! -path "${path}/.zfs" -print -quit 2>/dev/null
}

labels_are_ready() {
    local path="$1"
    local sample

    if [[ "$(stat -c '%C' "${path}")" != "${EXPECTED_LABEL}" ]]; then
        return 1
    fi

    sample="$(sample_descendant "${path}")"
    [[ -z "${sample}" || "$(stat -c '%C' "${sample}")" == "${EXPECTED_LABEL}" ]]
}

restorecon_recursive() {
    local path="$1"
    local args=(-F -R)

    if [[ -d "${path}/.zfs" ]]; then
        args+=(-e "${path}/.zfs")
    fi

    restorecon "${args[@]}" "${path}"
}

validate_mount() {
    local dataset="$1"
    local path="$2"
    local mounted_source

    mounted_source="$(findmnt -rn -o SOURCE -T "${path}" 2>/dev/null || true)"
    if [[ "${mounted_source}" != "${dataset}" ]]; then
        log "ERROR: ${path} is mounted from '${mounted_source:-nothing}', expected '${dataset}'"
        exit 1
    fi
}

prepare_labels() {
    local path="$1"

    ensure_fcontext_rule "${path}(/.*)?"
    restorecon -F "${path}"

    if ! labels_are_ready "${path}"; then
        log "SELinux labels incorrect in ${path}, relabeling..."
        restorecon_recursive "${path}"
    fi

    if ! labels_are_ready "${path}"; then
        log "ERROR: ${path} does not have the expected SELinux label ${EXPECTED_LABEL}"
        exit 1
    fi
}

# Check if pool exists
if ! zpool list -H -o name | grep -q "^${POOL}$"; then
    log "ERROR: Pool '${POOL}' does not exist"
    exit 1
fi

# Create parent dataset (not mounted - just a container for child datasets)
# Secrets live in /var/lib/garage/ on the root filesystem (via tmpfiles)
install -d -m 0755 -o root -g root /var/lib/garage

if dataset_exists "${BASE_DATASET}"; then
    log "Dataset ${BASE_DATASET} already exists, skipping"
else
    log "Creating ${BASE_DATASET} (unmounted parent)"
    zfs create -o mountpoint=none "${BASE_DATASET}"
fi

# Create metadata dataset - optimized for small random I/O (SQLite)
# - recordsize=4K: matches SQLite page size, reduces write amplification
# - compression=lz4: metadata is compressible text/indexes, lz4 is fast
# - atime=off: no need to track access times
# - primarycache=metadata: hint for caching
if dataset_exists "${META_DATASET}"; then
    log "Dataset ${META_DATASET} already exists, skipping"
else
    log "Creating ${META_DATASET} (optimized for database workload)"
    zfs create \
        -o mountpoint="${META_PATH}" \
        -o recordsize=4K \
        -o compression=lz4 \
        -o atime=off \
        -o primarycache=metadata \
        "${META_DATASET}"
fi

# Create data dataset - optimized for large sequential I/O (object blocks)
# - recordsize=1M: matches Garage's default block_size (1MiB)
# - compression=off: Garage already uses zstd compression, avoid double compression
# - atime=off: no need to track access times
if dataset_exists "${DATA_DATASET}"; then
    log "Dataset ${DATA_DATASET} already exists, skipping"
else
    log "Creating ${DATA_DATASET} (optimized for object storage)"
    zfs create \
        -o mountpoint="${DATA_PATH}" \
        -o recordsize=1M \
        -o compression=off \
        -o atime=off \
        "${DATA_DATASET}"
fi

validate_mount "${META_DATASET}" "${META_PATH}"
validate_mount "${DATA_DATASET}" "${DATA_PATH}"
prepare_labels "${META_PATH}"
prepare_labels "${DATA_PATH}"

log "Garage ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${META_DATASET}" "${DATA_DATASET}"
