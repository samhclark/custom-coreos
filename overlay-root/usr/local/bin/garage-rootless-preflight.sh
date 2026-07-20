#!/bin/bash
# ABOUTME: Records a one-time, read-only baseline before Garage's rootless
# ownership migration.

set -euo pipefail

REPORT_DIR="/var/lib/nas-migrations/garage-rootless-preflight-v1"
EXPECTED_LABEL="system_u:object_r:container_file_t:s0"
BASE_DATASET="tank/garage"
SNAPSHOT_NAME="rootless-preflight-v1"
snapshot_created=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

capture() {
    local name="$1"
    shift

    log "Recording ${name}"
    "$@" 2>&1 | tee "${REPORT_DIR}/${name}.txt"
}

cleanup() {
    if [[ "${snapshot_created}" -eq 1 ]]; then
        log "Removing temporary recursive snapshot ${BASE_DATASET}@${SNAPSHOT_NAME}"
        zfs destroy -r "${BASE_DATASET}@${SNAPSHOT_NAME}" || true
    fi
}
trap cleanup EXIT

wait_for_garage() {
    local _

    for _ in {1..150}; do
        if curl -fsS http://127.0.0.1:3903/health >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done

    log "ERROR: Garage did not become healthy within 300 seconds"
    return 1
}

scan_dataset() {
    local name="$1"
    local path="$2"
    local report="${REPORT_DIR}/${name}-scan.txt"
    local started elapsed unexpected_owner unexpected_label

    log "Scanning ${path}; this can take a long time on a large dataset"
    started="${SECONDS}"
    find "${path}" -xdev -path "${path}/.zfs" -prune -o -mindepth 1 \
        -printf '%U\t%G\t%Z\t%p\0' |
        awk -v RS='\0' -F '\t' -v expected="${EXPECTED_LABEL}" '
            {
                count++
                if (unexpected_owner == "" && ($1 != "0" || $2 != "0")) {
                    unexpected_owner = $4
                }
                if (unexpected_label == "" && $3 != expected) {
                    unexpected_label = $4
                }
            }
            END {
                printf "entries=%d\n", count
                printf "first_unexpected_owner=%s\n", unexpected_owner
                printf "first_unexpected_label=%s\n", unexpected_label
            }
        ' | tee "${report}"
    elapsed="$((SECONDS - started))"
    printf 'elapsed_seconds=%s\n' "${elapsed}" | tee -a "${report}"

    unexpected_owner="$(sed -n 's/^first_unexpected_owner=//p' "${report}")"
    unexpected_label="$(sed -n 's/^first_unexpected_label=//p' "${report}")"
    if [[ -n "${unexpected_owner}" || -n "${unexpected_label}" ]]; then
        log "ERROR: ${path} contains unexpected ownership or SELinux labels"
        return 1
    fi
}

install -d -m 0700 -o root -g root "${REPORT_DIR}"
wait_for_garage

capture timestamp date --iso-8601=seconds
capture image podman inspect garage --format \
    'image={{.ImageName}} image_id={{.Image}} user={{json .Config.User}}'
capture version podman exec garage /garage --version
capture node-id podman exec garage /garage node id
capture status podman exec garage /garage status
capture layout podman exec garage /garage layout show
capture buckets podman exec garage /garage bucket list
capture health curl -fsS http://127.0.0.1:3903/health
capture mounts bash -c '
    findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS -T /var/lib/garage/meta
    findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS -T /var/lib/garage/data
'
capture datasets zfs list -o \
    name,used,refer,avail,usedbysnapshots,mounted,mountpoint,recordsize,compression,atime \
    tank/garage tank/garage/meta tank/garage/data
capture properties zfs get canmount,mounted,readonly,snapdir,xattr,acltype \
    tank/garage/meta tank/garage/data
capture snapshots bash -c '
    zfs list -r -t snapshot -o name,used,refer,creation tank/garage || true
'
capture pool zpool list tank
capture roots stat -c '%u:%g %a %C %n' \
    /var/lib/garage/meta /var/lib/garage/data
capture listeners bash -c \
    "ss -ltnp | awk '\$4 ~ /:390[0-3]\$/ { print }'"

if zfs list -H -t snapshot "${BASE_DATASET}@${SNAPSHOT_NAME}" >/dev/null 2>&1; then
    log "Removing stale temporary recursive snapshot ${BASE_DATASET}@${SNAPSHOT_NAME}"
    zfs destroy -r "${BASE_DATASET}@${SNAPSHOT_NAME}"
fi

log "Creating temporary recursive snapshot ${BASE_DATASET}@${SNAPSHOT_NAME}"
zfs snapshot -r "${BASE_DATASET}@${SNAPSHOT_NAME}"
snapshot_created=1

scan_dataset meta "/var/lib/garage/meta/.zfs/snapshot/${SNAPSHOT_NAME}"
scan_dataset data "/var/lib/garage/data/.zfs/snapshot/${SNAPSHOT_NAME}"

log "Removing temporary recursive snapshot ${BASE_DATASET}@${SNAPSHOT_NAME}"
zfs destroy -r "${BASE_DATASET}@${SNAPSHOT_NAME}"
snapshot_created=0

touch "${REPORT_DIR}/complete"
log "Garage rootless preflight completed: ${REPORT_DIR}"
