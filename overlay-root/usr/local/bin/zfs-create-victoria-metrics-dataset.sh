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
DATA_DATASET="${BASE_DATASET}/data"
DATA_PATH="/var/lib/victoria-metrics"
SERVICE_USER="_nas_victoriametrics"
SERVICE_UID="51250"
SERVICE_GID="51250"
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
    find "${DATA_PATH}" -xdev -mindepth 1 -maxdepth 1 \
        ! -path "${DATA_PATH}/.zfs" -print -quit 2>/dev/null
}

labels_are_ready() {
    local sample

    if [[ "$(stat -c '%C' "${DATA_PATH}")" != "${EXPECTED_LABEL}" ]]; then
        return 1
    fi

    sample="$(sample_descendant)"
    [[ -z "${sample}" || "$(stat -c '%C' "${sample}")" == "${EXPECTED_LABEL}" ]]
}

restorecon_recursive() {
    local args=(-F -R)

    # Visible ZFS snapshot trees are read-only and must not be traversed.
    if [[ -d "${DATA_PATH}/.zfs" ]]; then
        args+=(-e "${DATA_PATH}/.zfs")
    fi

    restorecon "${args[@]}" "${DATA_PATH}"
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
if dataset_exists "${DATA_DATASET}"; then
    log "Dataset ${DATA_DATASET} already exists, skipping"
else
    log "Creating ${DATA_DATASET} (optimized for time-series storage)"
    zfs create \
        -o mountpoint="${DATA_PATH}" \
        -o recordsize=128K \
        -o compression=lz4 \
        -o atime=off \
        "${DATA_DATASET}"
fi

if ! getent passwd "${SERVICE_USER}" >/dev/null; then
    log "ERROR: Service user '${SERVICE_USER}' does not exist"
    exit 1
fi

if [[ "$(id -u "${SERVICE_USER}")" != "${SERVICE_UID}" || "$(id -g "${SERVICE_USER}")" != "${SERVICE_GID}" ]]; then
    log "ERROR: Service user '${SERVICE_USER}' does not have expected UID/GID ${SERVICE_UID}:${SERVICE_GID}"
    exit 1
fi

mounted_source="$(findmnt -rn -o SOURCE -T "${DATA_PATH}" 2>/dev/null || true)"
if [[ "${mounted_source}" != "${DATA_DATASET}" ]]; then
    log "ERROR: ${DATA_PATH} is mounted from '${mounted_source:-nothing}', expected '${DATA_DATASET}'"
    exit 1
fi

ensure_fcontext_rule "${DATA_PATH}(/.*)?"
restorecon -F "${DATA_PATH}"

ownership_migration=0
relabel_migration=0

# Rootless container UID 0 maps to the host service UID. Change descendants
# first, but leave the dataset root as the incomplete-migration marker until
# both ownership and SELinux preparation have succeeded.
if [[ "$(stat -c '%u:%g' "${DATA_PATH}")" != "${SERVICE_UID}:${SERVICE_GID}" ]]; then
    ownership_migration=1
    log "Migrating ${DATA_PATH} ownership to ${SERVICE_USER} (${SERVICE_UID}:${SERVICE_GID})"
    find "${DATA_PATH}" -xdev -path "${DATA_PATH}/.zfs" -prune -o \
        -mindepth 1 -exec chown -h "${SERVICE_UID}:${SERVICE_GID}" {} +
fi

if [[ "${ownership_migration}" -eq 1 ]] || ! labels_are_ready; then
    log "SELinux labels incorrect in ${DATA_PATH}, relabeling..."

    # If ownership was already migrated, temporarily clear the root marker so
    # an interrupted relabel is retried as a full migration on the next run.
    if [[ "${ownership_migration}" -eq 0 ]]; then
        chown root:root "${DATA_PATH}"
        relabel_migration=1
    fi

    # -F resets the full context, including stale Podman MCS categories.
    restorecon_recursive
fi

if ! labels_are_ready; then
    log "ERROR: ${DATA_PATH} does not have the expected SELinux label ${EXPECTED_LABEL}"
    exit 1
fi

if [[ "${ownership_migration}" -eq 1 || "${relabel_migration}" -eq 1 ]]; then
    chown "${SERVICE_UID}:${SERVICE_GID}" "${DATA_PATH}"
fi
chmod 0750 "${DATA_PATH}"

log "VictoriaMetrics ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${DATA_DATASET}"
