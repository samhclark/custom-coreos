#!/bin/bash
# ABOUTME: Archives and prepares Caddy's two small persistent state trees for
# the one-time transition from rootful Podman to the _nas_caddy user.

set -euo pipefail

SERVICE_USER="_nas_caddy"
SERVICE_UID="51310"
SERVICE_GID="51310"
EXPECTED_LABEL="system_u:object_r:container_file_t:s0"
PREFLIGHT_COMPLETE="/var/lib/nas-migrations/caddy-rootless-preflight-v1/complete"
MIGRATION_DIR="/var/lib/nas-migrations/caddy-rootless-ownership-v1"
MIGRATION_COMPLETE="${MIGRATION_DIR}/complete"
ARCHIVE="${MIGRATION_DIR}/pre-rootless-state.tar"
ARCHIVE_CHECKSUM="${ARCHIVE}.sha256"
STATE_PATHS=(/var/lib/caddy /var/lib/caddy-config)
archive_tmp=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    if [[ -n "${archive_tmp}" && -e "${archive_tmp}" ]]; then
        rm -f "${archive_tmp}"
    fi
}
trap cleanup EXIT

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

ensure_fcontext_rule() {
    local target="$1"

    if semanage fcontext -a -t container_file_t -r s0 "${target}" 2>/dev/null; then
        log "Added SELinux fcontext for ${target}"
        return
    fi

    semanage fcontext -m -t container_file_t -r s0 "${target}"
}

container_is_running() {
    local store="$1"
    local running
    local status

    if [[ "${store}" == "rootful" ]]; then
        if podman container exists caddy >/dev/null 2>&1; then
            running="$(podman inspect caddy --format '{{.State.Running}}')" ||
                fail "Unable to inspect the rootful Caddy container"
            [[ "${running}" == "true" ]]
            return
        else
            status=$?
        fi
    else
        if rootless_podman container exists caddy >/dev/null 2>&1; then
            running="$(rootless_podman inspect caddy --format '{{.State.Running}}')" ||
                fail "Unable to inspect the rootless Caddy container"
            [[ "${running}" == "true" ]]
            return
        else
            status=$?
        fi
    fi

    [[ "${status}" -eq 1 ]] ||
        fail "Unable to query the ${store} Podman store for Caddy"
    return 1
}

ensure_caddy_stopped() {
    local listeners

    [[ ! -e /etc/containers/systemd/caddy.container ]] ||
        fail "The retired rootful Caddy Quadlet still exists"
    ! systemctl is-active --quiet caddy.service ||
        fail "The system-manager caddy.service is still active"
    ! container_is_running rootful ||
        fail "The rootful Caddy container is still running"
    ! container_is_running rootless ||
        fail "The rootless Caddy container is already running"

    listeners="$(
        {
            ss -H -ltn
            ss -H -lun
        } | grep -E ':(80|443)[[:space:]]' || true
    )"
    [[ -z "${listeners}" ]] ||
        fail "A process already owns TCP or UDP port 80 or 443: ${listeners}"
}

validate_original_ownership() {
    local unexpected

    unexpected="$(
        find "${STATE_PATHS[@]}" -xdev \
            \( ! -uid 0 -o ! -gid 0 \) -print -quit
    )"
    [[ -z "${unexpected}" ]] ||
        fail "Cannot create the original archive after ownership changed: ${unexpected}"
}

validate_archive() {
    validate_archive_contents
    [[ -e "${ARCHIVE_CHECKSUM}" ]] ||
        fail "The Caddy rollback archive has no completed checksum"
    (
        cd "${MIGRATION_DIR}"
        sha256sum --check "$(basename "${ARCHIVE_CHECKSUM}")"
    ) >/dev/null || fail "The Caddy rollback archive checksum does not match"
}

validate_archive_contents() {
    tar --list --file "${ARCHIVE}" >/dev/null ||
        fail "The Caddy rollback archive is unreadable"
    tar --list --file "${ARCHIVE}" |
        grep -Fx 'var/lib/caddy/' >/dev/null ||
        fail "The Caddy rollback archive is missing /var/lib/caddy"
    tar --list --file "${ARCHIVE}" |
        grep -Fx 'var/lib/caddy-config/' >/dev/null ||
        fail "The Caddy rollback archive is missing /var/lib/caddy-config"
}

compare_archive_to_original() {
    tar --compare \
        --file "${ARCHIVE}" \
        --acls \
        --xattrs \
        --selinux \
        --numeric-owner \
        --directory / ||
        fail "The Caddy rollback archive does not match the original state"
}

write_archive_checksum() {
    (
        cd "${MIGRATION_DIR}"
        sha256sum "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE_CHECKSUM}")"
    )
    chmod 0600 "${ARCHIVE_CHECKSUM}"
    sync "${ARCHIVE}" "${ARCHIVE_CHECKSUM}"
}

ensure_archive() {
    if [[ -e "${ARCHIVE}" ]]; then
        if [[ ! -e "${ARCHIVE_CHECKSUM}" ]]; then
            log "Completing verification of an interrupted Caddy archive"
            validate_original_ownership
            validate_archive_contents
            compare_archive_to_original
            write_archive_checksum
        fi
        log "Reusing verified Caddy rollback archive"
        validate_archive
        return
    fi

    [[ ! -e "${ARCHIVE_CHECKSUM}" ]] ||
        fail "A rollback checksum exists without its archive"
    validate_original_ownership

    archive_tmp="$(mktemp "${MIGRATION_DIR}/.pre-rootless-state.XXXXXX.tar")"

    log "Archiving Caddy state before ownership and SELinux changes"
    tar --create \
        --file "${archive_tmp}" \
        --acls \
        --xattrs \
        --selinux \
        --numeric-owner \
        --one-file-system \
        --directory / \
        var/lib/caddy \
        var/lib/caddy-config
    chmod 0600 "${archive_tmp}"
    mv "${archive_tmp}" "${ARCHIVE}"
    archive_tmp=""
    validate_archive_contents
    compare_archive_to_original
    write_archive_checksum
    validate_archive
}

verify_prepared_state() {
    local path
    local unexpected

    unexpected="$(
        find "${STATE_PATHS[@]}" -xdev \
            \( ! -uid "${SERVICE_UID}" -o ! -gid "${SERVICE_GID}" \) \
            -print -quit
    )"
    [[ -z "${unexpected}" ]] ||
        fail "${unexpected} has unexpected ownership after migration"

    unexpected="$(
        find "${STATE_PATHS[@]}" -xdev \
            ! -context "${EXPECTED_LABEL}" -print -quit
    )"
    [[ -z "${unexpected}" ]] ||
        fail "${unexpected} has an unexpected SELinux label after migration"

    for path in "${STATE_PATHS[@]}"; do
        [[ "$(stat -c '%u:%g' "${path}")" == "${SERVICE_UID}:${SERVICE_GID}" ]] ||
            fail "${path} root has unexpected ownership"
        [[ "$(stat -c '%a' "${path}")" == "750" ]] ||
            fail "${path} root has unexpected mode"
        [[ "$(stat -c '%C' "${path}")" == "${EXPECTED_LABEL}" ]] ||
            fail "${path} root has an unexpected SELinux label"
    done
}

if [[ -e "${MIGRATION_COMPLETE}" ]]; then
    log "Caddy rootless state migration is already complete"
    exit 0
fi

[[ -e "${PREFLIGHT_COMPLETE}" ]] ||
    fail "The completed Caddy rootless preflight report is required"

if ! getent passwd "${SERVICE_USER}" >/dev/null; then
    fail "Service user ${SERVICE_USER} does not exist"
fi
[[ "$(id -u "${SERVICE_USER}")" == "${SERVICE_UID}" ]] ||
    fail "${SERVICE_USER} does not have UID ${SERVICE_UID}"
[[ "$(id -g "${SERVICE_USER}")" == "${SERVICE_GID}" ]] ||
    fail "${SERVICE_USER} does not have GID ${SERVICE_GID}"

for path in "${STATE_PATHS[@]}"; do
    [[ -d "${path}" ]] || fail "Required Caddy state directory is missing: ${path}"
done

install -d -m 0755 -o root -g root /var/lib/nas-migrations
install -d -m 0711 -o root -g root "${MIGRATION_DIR}"
ensure_caddy_stopped
ensure_archive

ensure_fcontext_rule "/var/lib/caddy(/.*)?"
ensure_fcontext_rule "/var/lib/caddy-config(/.*)?"

# Both roots remain root-owned as the durable incomplete-operation indicator
# until every descendant has the final owner and SELinux label.
chown root:root "${STATE_PATHS[@]}"

log "Changing Caddy state descendants to ${SERVICE_UID}:${SERVICE_GID}"
find "${STATE_PATHS[@]}" -xdev -mindepth 1 \
    -exec chown -h "${SERVICE_UID}:${SERVICE_GID}" {} +

log "Resetting Caddy state to the persistent container_file_t:s0 policy"
restorecon -F -R "${STATE_PATHS[@]}"

# Roots are deliberately changed last. If anything above is interrupted, the
# absent completion marker and root ownership cause the entire pass to retry.
chown "${SERVICE_UID}:${SERVICE_GID}" "${STATE_PATHS[@]}"
chmod 0750 "${STATE_PATHS[@]}"
verify_prepared_state

install -m 0644 -o root -g root /dev/null "${MIGRATION_COMPLETE}"
sync "${MIGRATION_COMPLETE}"
log "Caddy rootless state migration completed"
