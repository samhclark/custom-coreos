#!/bin/bash
# ABOUTME: Creates and verifies Caddy's persistent state for its rootless
# service account.

set -euo pipefail

SERVICE_USER="_nas_caddy"
SERVICE_UID="51310"
SERVICE_GID="51310"
EXPECTED_LABEL="system_u:object_r:container_file_t:s0"
STATE_PATHS=(/var/lib/caddy /var/lib/caddy-config)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

ensure_fcontext_rule() {
    local target="$1"

    if semanage fcontext -a -t container_file_t -r s0 "${target}" 2>/dev/null; then
        log "Added SELinux fcontext for ${target}"
        return
    fi

    semanage fcontext -m -t container_file_t -r s0 "${target}"
}

verify_identity() {
    getent passwd "${SERVICE_USER}" >/dev/null ||
        fail "Service user ${SERVICE_USER} does not exist"
    [[ "$(id -u "${SERVICE_USER}")" == "${SERVICE_UID}" ]] ||
        fail "${SERVICE_USER} does not have UID ${SERVICE_UID}"
    [[ "$(id -g "${SERVICE_USER}")" == "${SERVICE_GID}" ]] ||
        fail "${SERVICE_USER} does not have GID ${SERVICE_GID}"
}

ensure_state_roots() {
    local path

    for path in "${STATE_PATHS[@]}"; do
        if [[ ! -e "${path}" ]]; then
            log "Creating ${path}"
            install -d -m 0750 -o "${SERVICE_UID}" -g "${SERVICE_GID}" "${path}"
        elif [[ ! -d "${path}" ]]; then
            fail "${path} exists but is not a directory"
        fi

        chmod 0750 "${path}"
    done
}

verify_state() {
    local path
    local unexpected

    for path in "${STATE_PATHS[@]}"; do
        if ! unexpected="$(
            find "${path}" -xdev \
                \( ! -uid "${SERVICE_UID}" -o ! -gid "${SERVICE_GID}" \) \
                -print -quit
        )"; then
            fail "Unable to verify ownership under ${path}"
        fi
        [[ -z "${unexpected}" ]] ||
            fail "${unexpected} does not have expected owner ${SERVICE_UID}:${SERVICE_GID}"

        if ! unexpected="$(
            find "${path}" -xdev ! -context "${EXPECTED_LABEL}" -print -quit
        )"; then
            fail "Unable to verify SELinux labels under ${path}"
        fi
        [[ -z "${unexpected}" ]] ||
            fail "${unexpected} does not have expected label ${EXPECTED_LABEL}"

        [[ "$(stat -c '%a' "${path}")" == "750" ]] ||
            fail "${path} root mode is not 0750"
    done
}

verify_identity
ensure_state_roots

ensure_fcontext_rule "/var/lib/caddy(/.*)?"
ensure_fcontext_rule "/var/lib/caddy-config(/.*)?"

log "Restoring Caddy state SELinux labels"
restorecon -F -R "${STATE_PATHS[@]}"

verify_state
log "Caddy state is ready"
