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
REPAIR_REQUEST="${MIGRATION_DIR}/repair-required"

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
        ! -path "${path}/.zfs" -print -quit
}

labels_are_ready() {
    local path="$1"
    local sample

    if [[ "$(stat -c '%C' "${path}")" != "${EXPECTED_LABEL}" ]]; then
        return 1
    fi

    if ! sample="$(sample_descendant "${path}")"; then
        return 1
    fi
    [[ -z "${sample}" || "$(stat -c '%C' "${sample}")" == "${EXPECTED_LABEL}" ]]
}

sample_owner_is_ready() {
    local path="$1"
    local sample

    if ! sample="$(sample_descendant "${path}")"; then
        return 1
    fi
    [[ -z "${sample}" || "$(stat -c '%u:%g' "${sample}")" == "${SERVICE_UID}:${SERVICE_GID}" ]]
}

bounded_state_is_ready() {
    local path="$1"

    if [[ "$(stat -c '%u:%g' "${path}")" != "${SERVICE_UID}:${SERVICE_GID}" ]]; then
        log "ERROR: ${path} root is not owned by ${SERVICE_UID}:${SERVICE_GID}"
        return 1
    fi

    if [[ "$(stat -c '%a' "${path}")" != "750" ]]; then
        log "ERROR: ${path} root mode is not 0750"
        return 1
    fi

    if ! labels_are_ready "${path}"; then
        log "ERROR: ${path} root or bounded sample has an unexpected SELinux label"
        return 1
    fi

    if ! sample_owner_is_ready "${path}"; then
        log "ERROR: ${path} bounded sample has unexpected ownership"
        return 1
    fi
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

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

ensure_garage_stopped() {
    local exists_status
    local listeners
    local running

    if podman container exists garage >/dev/null 2>&1; then
        if ! running="$(podman inspect garage --format '{{.State.Running}}')"; then
            log "ERROR: Unable to inspect the rootful Garage container"
            exit 1
        fi
        if [[ "${running}" == "true" ]]; then
            log "ERROR: Refusing to mutate Garage storage while the rootful container is running"
            exit 1
        fi
    else
        exists_status=$?
        if [[ "${exists_status}" -ne 1 ]]; then
            log "ERROR: Unable to query the rootful Podman store for Garage"
            exit 1
        fi
    fi

    if rootless_podman container exists garage >/dev/null 2>&1; then
        if ! running="$(rootless_podman inspect garage --format '{{.State.Running}}')"; then
            log "ERROR: Unable to inspect the rootless Garage container"
            exit 1
        fi
        if [[ "${running}" == "true" ]]; then
            log "ERROR: Refusing to mutate Garage storage while the rootless container is running"
            exit 1
        fi
    else
        exists_status=$?
        if [[ "${exists_status}" -ne 1 ]]; then
            log "ERROR: Unable to query ${SERVICE_USER}'s Podman store for Garage"
            exit 1
        fi
    fi

    if ! listeners="$(ss -H -ltn)"; then
        log "ERROR: Unable to inspect Garage host ports"
        exit 1
    fi
    if awk '$4 ~ /:390(0|2|3)$/ { found=1 } END { exit !found }' <<< "${listeners}"; then
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

    if ! unexpected="$(find "${path}" -xdev -path "${path}/.zfs" -prune -o \
        -mindepth 1 \( ! -uid "${SERVICE_UID}" -o ! -gid "${SERVICE_GID}" \) \
        -print -quit)"; then
        log "ERROR: Unable to verify ownership under ${path}"
        exit 1
    fi

    if [[ -n "${unexpected}" ]]; then
        log "ERROR: ${unexpected} does not have expected owner ${SERVICE_UID}:${SERVICE_GID}"
        exit 1
    fi
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

preparation_mode="normal"
if [[ ! -e "${MIGRATION_COMPLETE}" ]]; then
    preparation_mode="initial"
    if { path_has_entries "${META_PATH}" || path_has_entries "${DATA_PATH}"; } && \
       [[ ! -e "${PREFLIGHT_COMPLETE}" ]]; then
        log "ERROR: Existing Garage data requires the completed rootless preflight report"
        exit 1
    fi
    ensure_rollback_snapshot
elif [[ -e "${REPAIR_REQUEST}" ]]; then
    preparation_mode="requested-repair"
elif [[ "$(stat -c '%u:%g' "${META_PATH}")" == "0:0" || \
        "$(stat -c '%u:%g' "${DATA_PATH}")" == "0:0" ]]; then
    preparation_mode="interrupted-repair"
fi

if [[ "${preparation_mode}" == "normal" ]]; then
    # Static service IDs make a recursive ownership scan unnecessary during an
    # ordinary rootless boot. Check roots and one immediate descendant only.
    # Deep repair is an explicit operation because it can take tens of minutes.
    for path in "${META_PATH}" "${DATA_PATH}"; do
        if ! bounded_state_is_ready "${path}"; then
            log "ERROR: Refusing an implicit full-tree scan. To request repair, create ${REPAIR_REQUEST} and restart this service"
            exit 1
        fi
    done
    log "Garage dataset roots and bounded samples are ready; skipped recursive ownership scan"
else
    log "Running full Garage dataset preparation (${preparation_mode})"

    # Arm both dataset roots before a requested or initial full pass. Their
    # root ownership remains the durable incomplete-operation marker until all
    # descendant ownership and labels have been verified.
    chown root:root "${META_PATH}" "${DATA_PATH}"
    prepare_dataset "${META_PATH}"
    prepare_dataset "${DATA_PATH}"
fi

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

if [[ "${preparation_mode}" == "requested-repair" ]]; then
    rm -f "${REPAIR_REQUEST}"
fi

log "Garage ZFS datasets ready"
zfs get recordsize,compression,atime,mountpoint "${BASE_DATASET}" "${META_DATASET}" "${DATA_DATASET}"
