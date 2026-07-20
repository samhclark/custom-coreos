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
SERVICE_USER="_nas_garage"
SERVICE_UID="51110"
SERVICE_GID="51110"
EXPECTED_LABEL="system_u:object_r:container_file_t:s0"
ROLLBACK_SNAPSHOT="pre-rootless-v1"
PREFLIGHT_COMPLETE="/var/lib/nas-migrations/garage-rootless-preflight-v1/complete"
MIGRATION_DIR="/var/lib/nas-migrations/garage-rootless-ownership-v1"
MIGRATION_COMPLETE="${MIGRATION_DIR}/complete"

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

path_has_entries() {
    local path="$1"
    local first

    if ! first="$(find "${path}" -xdev -path "${path}/.zfs" -prune -o \
        -mindepth 1 -print -quit)"; then
        log "ERROR: Unable to inspect ${path} before ownership migration"
        exit 1
    fi

    [[ -n "${first}" ]]
}

validate_root_owner() {
    local path="$1"
    local owner

    owner="$(stat -c '%u:%g' "${path}")"
    if [[ "${owner}" != "0:0" && "${owner}" != "${SERVICE_UID}:${SERVICE_GID}" ]]; then
        log "ERROR: ${path} has unexpected owner ${owner}; expected 0:0 or ${SERVICE_UID}:${SERVICE_GID}"
        exit 1
    fi
}

ensure_garage_stopped() {
    local rootful_running

    rootful_running="$(podman inspect garage --format '{{.State.Running}}' 2>/dev/null || true)"
    if [[ "${rootful_running}" == "true" ]]; then
        log "ERROR: Refusing to mutate Garage storage while the rootful container is running"
        exit 1
    fi

    if ss -H -ltn | awk '$4 ~ /:390(0|2|3)$/ { found=1 } END { exit !found }'; then
        log "ERROR: Refusing to mutate Garage storage while a process listens on a Garage host port"
        exit 1
    fi
}

ensure_rollback_snapshot() {
    local dataset
    local present=0
    local missing=0

    for dataset in "${BASE_DATASET}" "${META_DATASET}" "${DATA_DATASET}"; do
        if zfs list -H -t snapshot "${dataset}@${ROLLBACK_SNAPSHOT}" >/dev/null 2>&1; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
        fi
    done

    if [[ "${present}" -ne 0 && "${missing}" -ne 0 ]]; then
        log "ERROR: Recursive rollback snapshot is incomplete; expected ${ROLLBACK_SNAPSHOT} on all Garage datasets"
        exit 1
    fi

    if [[ "${present}" -eq 3 ]]; then
        log "Reusing coordinated rollback snapshot ${BASE_DATASET}@${ROLLBACK_SNAPSHOT}"
        return
    fi

    if [[ "$(stat -c '%u:%g' "${META_PATH}")" != "0:0" || \
          "$(stat -c '%u:%g' "${DATA_PATH}")" != "0:0" ]]; then
        log "ERROR: Cannot establish the original rollback point after a dataset root changed ownership"
        exit 1
    fi

    log "Creating coordinated rollback snapshot ${BASE_DATASET}@${ROLLBACK_SNAPSHOT}"
    zfs snapshot -r "${BASE_DATASET}@${ROLLBACK_SNAPSHOT}"
}

verify_descendant_owners() {
    local path="$1"
    local unexpected

    unexpected="$(find "${path}" -xdev -path "${path}/.zfs" -prune -o \
        -mindepth 1 \( ! -uid "${SERVICE_UID}" -o ! -gid "${SERVICE_GID}" \) \
        -print -quit 2>/dev/null)"
    if [[ -n "${unexpected}" ]]; then
        log "ERROR: ${unexpected} does not have expected owner ${SERVICE_UID}:${SERVICE_GID}"
        exit 1
    fi
}

descendant_owners_are_ready() {
    local path="$1"
    local unexpected

    if ! unexpected="$(find "${path}" -xdev -path "${path}/.zfs" -prune -o \
        -mindepth 1 \( ! -uid "${SERVICE_UID}" -o ! -gid "${SERVICE_GID}" \) \
        -print -quit)"; then
        log "ERROR: Unable to verify ownership under ${path}"
        exit 1
    fi

    [[ -z "${unexpected}" ]]
}

prepare_dataset() {
    local path="$1"
    local owner
    local ownership_migration=0
    local relabel_migration=0

    owner="$(stat -c '%u:%g' "${path}")"

    # Rootless container UID 0 maps to the host service UID. Descendants are
    # changed first; the dataset root remains the incomplete-migration marker.
    if [[ "${owner}" == "0:0" ]]; then
        ownership_migration=1
        log "Migrating ${path} ownership to ${SERVICE_USER} (${SERVICE_UID}:${SERVICE_GID})"
        find "${path}" -xdev -path "${path}/.zfs" -prune -o \
            -mindepth 1 -exec chown -h "${SERVICE_UID}:${SERVICE_GID}" {} +
    fi

    if [[ "${ownership_migration}" -eq 1 ]] || ! labels_are_ready "${path}"; then
        log "Restoring SELinux labels in ${path}"

        # Temporarily clear a completed root marker so an interrupted relabel
        # is retried as incomplete on the next preparation run.
        if [[ "${ownership_migration}" -eq 0 ]]; then
            chown root:root "${path}"
            relabel_migration=1
        fi

        restorecon_recursive "${path}"
    fi

    if ! labels_are_ready "${path}"; then
        log "ERROR: ${path} does not have the expected SELinux label ${EXPECTED_LABEL}"
        exit 1
    fi

    if [[ "${ownership_migration}" -eq 1 ]]; then
        verify_descendant_owners "${path}"
    fi

    if [[ "${ownership_migration}" -eq 1 || "${relabel_migration}" -eq 1 ]]; then
        chown "${SERVICE_UID}:${SERVICE_GID}" "${path}"
    fi
    chmod 0750 "${path}"
}

# Check if pool exists
if ! zpool list -H -o name | grep -q "^${POOL}$"; then
    log "ERROR: Pool '${POOL}' does not exist"
    exit 1
fi

# Create the parent mount path and unmounted dataset container for the children.
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

if ! getent passwd "${SERVICE_USER}" >/dev/null; then
    log "ERROR: Service user '${SERVICE_USER}' does not exist"
    exit 1
fi

if [[ "$(id -u "${SERVICE_USER}")" != "${SERVICE_UID}" || \
      "$(id -g "${SERVICE_USER}")" != "${SERVICE_GID}" ]]; then
    log "ERROR: Service user '${SERVICE_USER}' does not have expected UID/GID ${SERVICE_UID}:${SERVICE_GID}"
    exit 1
fi

ensure_fcontext_rule "${META_PATH}(/.*)?"
ensure_fcontext_rule "${DATA_PATH}(/.*)?"
validate_root_owner "${META_PATH}"
validate_root_owner "${DATA_PATH}"
ensure_garage_stopped

migration_needed=0
repair_meta_descendants=0
repair_data_descendants=0
if [[ "$(stat -c '%u:%g' "${META_PATH}")" != "${SERVICE_UID}:${SERVICE_GID}" || \
      "$(stat -c '%u:%g' "${DATA_PATH}")" != "${SERVICE_UID}:${SERVICE_GID}" ]]; then
    migration_needed=1
fi
if ! descendant_owners_are_ready "${META_PATH}"; then
    log "Ownership drift detected under ${META_PATH}; scheduling a full repair"
    repair_meta_descendants=1
    migration_needed=1
fi
if ! descendant_owners_are_ready "${DATA_PATH}"; then
    log "Ownership drift detected under ${DATA_PATH}; scheduling a full repair"
    repair_data_descendants=1
    migration_needed=1
fi

if [[ ! -e "${MIGRATION_COMPLETE}" ]]; then
    if { path_has_entries "${META_PATH}" || path_has_entries "${DATA_PATH}"; } && \
       [[ ! -e "${PREFLIGHT_COMPLETE}" ]]; then
        log "ERROR: Existing Garage data requires the completed rootless preflight report"
        exit 1
    fi
    ensure_rollback_snapshot
elif [[ "${migration_needed}" -eq 1 ]]; then
    log "Repairing an interrupted post-migration ownership or label operation"
fi

# A bootc rollback can run rootful Garage against roots that retain UID 51110,
# creating new root-owned descendants. Re-arm only the affected root markers
# after Garage is confirmed stopped so the normal root-last transaction repairs
# those trees before readiness is published.
if [[ "${repair_meta_descendants}" -eq 1 ]]; then
    chown root:root "${META_PATH}"
fi
if [[ "${repair_data_descendants}" -eq 1 ]]; then
    chown root:root "${DATA_PATH}"
fi

prepare_dataset "${META_PATH}"
prepare_dataset "${DATA_PATH}"

for path in "${META_PATH}" "${DATA_PATH}"; do
    if [[ "$(stat -c '%u:%g' "${path}")" != "${SERVICE_UID}:${SERVICE_GID}" || \
          "$(stat -c '%a' "${path}")" != "750" ]]; then
        log "ERROR: ${path} root did not reach expected owner/mode ${SERVICE_UID}:${SERVICE_GID} 0750"
        exit 1
    fi
done

if [[ ! -e "${MIGRATION_COMPLETE}" ]]; then
    install -d -m 0700 -o root -g root "${MIGRATION_DIR}"
    touch "${MIGRATION_COMPLETE}"
fi

log "Garage ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${META_DATASET}" "${DATA_DATASET}"
