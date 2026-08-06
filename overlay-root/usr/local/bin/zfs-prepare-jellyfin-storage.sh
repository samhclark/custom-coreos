#!/bin/bash
# ABOUTME: Creates Jellyfin's config/cache datasets and prepares read-only
# SELinux access to the existing tank/videos media dataset.

set -euo pipefail

POOL="tank"
BASE_DATASET="${POOL}/jellyfin"
CONFIG_DATASET="${BASE_DATASET}/config"
CACHE_DATASET="${BASE_DATASET}/cache"
MEDIA_DATASET="${POOL}/videos"
CONFIG_PATH="/var/lib/jellyfin/config"
CACHE_PATH="/var/lib/jellyfin/cache"
MEDIA_PATH="/var/zfs/tank/videos"
MOVIES_PATH="${MEDIA_PATH}/movies"
TV_PATH="${MEDIA_PATH}/tv-shows"
SERVICE_USER="_nas_jellyfin"
SERVICE_UID="51120"
SERVICE_GID="51120"
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

owners_are_ready() {
    local path="$1"
    local sample

    if [[ "$(stat -c '%u:%g' "${path}")" != "${SERVICE_UID}:${SERVICE_GID}" ]]; then
        return 1
    fi

    sample="$(sample_descendant "${path}")"
    [[ -z "${sample}" || "$(stat -c '%u:%g' "${sample}")" == "${SERVICE_UID}:${SERVICE_GID}" ]]
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

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

ensure_jellyfin_stopped() {
    local exists_status
    local listeners
    local running

    if rootless_podman container exists jellyfin >/dev/null 2>&1; then
        if ! running="$(rootless_podman inspect jellyfin --format '{{.State.Running}}')"; then
            log "ERROR: Unable to inspect the rootless Jellyfin container"
            exit 1
        fi
        if [[ "${running}" == "true" ]]; then
            log "ERROR: Refusing to mutate Jellyfin storage while its container is running"
            exit 1
        fi
    else
        exists_status=$?
        if [[ "${exists_status}" -ne 1 ]]; then
            log "ERROR: Unable to query ${SERVICE_USER}'s Podman store"
            exit 1
        fi
    fi

    if ! listeners="$(ss -H -ltn)"; then
        log "ERROR: Unable to inspect Jellyfin host port"
        exit 1
    fi
    if awk '$4 ~ /:8096$/ { found=1 } END { exit !found }' <<< "${listeners}"; then
        log "ERROR: Refusing to mutate Jellyfin storage while a process listens on port 8096"
        exit 1
    fi
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

prepare_writable_dataset() {
    local path="$1"

    if owners_are_ready "${path}" && labels_are_ready "${path}"; then
        chmod 0750 "${path}"
        return
    fi

    ensure_jellyfin_stopped
    chown root:root "${path}"
    find "${path}" -xdev -path "${path}/.zfs" -prune -o \
        -mindepth 1 -exec chown -h "${SERVICE_UID}:${SERVICE_GID}" {} +
    verify_descendant_owners "${path}"
    restorecon_recursive "${path}"

    if ! labels_are_ready "${path}"; then
        log "ERROR: ${path} does not have the expected SELinux label ${EXPECTED_LABEL}"
        exit 1
    fi

    chown "${SERVICE_UID}:${SERVICE_GID}" "${path}"
    chmod 0750 "${path}"
}

if ! zpool list -H -o name | grep -q "^${POOL}$"; then
    log "ERROR: Pool '${POOL}' does not exist"
    exit 1
fi

if ! dataset_exists "${MEDIA_DATASET}"; then
    log "ERROR: Required existing media dataset '${MEDIA_DATASET}' does not exist"
    exit 1
fi

install -d -m 0755 -o root -g root /var/lib/jellyfin

if dataset_exists "${BASE_DATASET}"; then
    log "Dataset ${BASE_DATASET} already exists, skipping"
else
    log "Creating ${BASE_DATASET} (unmounted parent)"
    zfs create -o mountpoint=none "${BASE_DATASET}"
fi

if dataset_exists "${CONFIG_DATASET}"; then
    log "Dataset ${CONFIG_DATASET} already exists, skipping"
else
    log "Creating ${CONFIG_DATASET} (Jellyfin database and configuration)"
    zfs create \
        -o mountpoint="${CONFIG_PATH}" \
        -o recordsize=16K \
        -o compression=lz4 \
        -o atime=off \
        "${CONFIG_DATASET}"
fi

if dataset_exists "${CACHE_DATASET}"; then
    log "Dataset ${CACHE_DATASET} already exists, skipping"
else
    log "Creating ${CACHE_DATASET} (Jellyfin cache and transcodes)"
    zfs create \
        -o mountpoint="${CACHE_PATH}" \
        -o recordsize=128K \
        -o compression=lz4 \
        -o atime=off \
        "${CACHE_DATASET}"
fi

validate_mount "${CONFIG_DATASET}" "${CONFIG_PATH}"
validate_mount "${CACHE_DATASET}" "${CACHE_PATH}"
validate_mount "${MEDIA_DATASET}" "${MEDIA_PATH}"

if ! getent passwd "${SERVICE_USER}" >/dev/null; then
    log "ERROR: Service user '${SERVICE_USER}' does not exist"
    exit 1
fi

if [[ "$(id -u "${SERVICE_USER}")" != "${SERVICE_UID}" || \
      "$(id -g "${SERVICE_USER}")" != "${SERVICE_GID}" ]]; then
    log "ERROR: Service user '${SERVICE_USER}' does not have expected UID/GID ${SERVICE_UID}:${SERVICE_GID}"
    exit 1
fi

ensure_fcontext_rule "${CONFIG_PATH}(/.*)?"
ensure_fcontext_rule "${CACHE_PATH}(/.*)?"
ensure_fcontext_rule "${MEDIA_PATH}(/.*)?"

prepare_writable_dataset "${CONFIG_PATH}"
prepare_writable_dataset "${CACHE_PATH}"

if ! labels_are_ready "${MEDIA_PATH}"; then
    ensure_jellyfin_stopped
    log "Restoring shared container SELinux labels under ${MEDIA_PATH}; this first pass may take a while"
    restorecon_recursive "${MEDIA_PATH}"
fi

if ! labels_are_ready "${MEDIA_PATH}"; then
    log "ERROR: ${MEDIA_PATH} root or bounded sample has an unexpected SELinux label"
    exit 1
fi

for library_path in "${MOVIES_PATH}" "${TV_PATH}"; do
    if [[ ! -d "${library_path}" ]]; then
        log "ERROR: Required Jellyfin library directory ${library_path} does not exist"
        exit 1
    fi

    if ! runuser -u "${SERVICE_USER}" -- test -r "${library_path}" || \
       ! runuser -u "${SERVICE_USER}" -- test -x "${library_path}"; then
        log "ERROR: ${SERVICE_USER} cannot read and traverse ${library_path}; fix host permissions without changing media ownership"
        exit 1
    fi
done

log "Jellyfin ZFS storage and read-only media access are ready"
zfs get recordsize,compression,atime,mountpoint \
    "${BASE_DATASET}" "${CONFIG_DATASET}" "${CACHE_DATASET}" "${MEDIA_DATASET}"
