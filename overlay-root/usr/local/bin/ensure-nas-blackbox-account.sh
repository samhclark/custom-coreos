#!/bin/bash
# ABOUTME: Repairs the persisted _nas_blackbox account state so the lingering
# user manager can start after bootc upgrades.

set -euo pipefail

USER_NAME="_nas_blackbox"
USER_UID="51230"
USER_HOME="/var/home/_nas_blackbox"
USER_SHELL="/sbin/nologin"
USER_SUBID_START="512300000"
USER_SUBID_COUNT="65536"
BLACKBOX_CONFIG_FCONTEXT="/usr/share/custom-coreos/blackbox-exporter(/.*)?"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ensure_subid_entry() {
    local file="$1"
    local expected="${USER_NAME}:${USER_SUBID_START}:${USER_SUBID_COUNT}"
    local current

    if [[ ! -e "${file}" ]]; then
        install -o root -g root -m 0644 /dev/null "${file}"
    fi

    current="$(grep -E "^${USER_NAME}:" "${file}" || true)"

    if [[ -z "${current}" ]]; then
        log "Adding ${expected} to ${file}"
        printf '%s\n' "${expected}" >> "${file}"
        return
    fi

    if [[ "${current}" != "${expected}" ]]; then
        log "Leaving existing ${file} entry for ${USER_NAME}: ${current}"
    fi
}

ensure_fcontext_rule() {
    local target="$1"

    if semanage fcontext -a -t container_file_t -r s0 "${target}" 2>/dev/null; then
        log "Added SELinux fcontext for ${target}"
        return
    fi

    semanage fcontext -m -t container_file_t -r s0 "${target}"
}

if ! getent passwd "${USER_NAME}" >/dev/null; then
    log "User ${USER_NAME} does not exist yet, skipping"
    exit 0
fi

shadow_entry="$(getent shadow "${USER_NAME}" || true)"
shadow_password_field="${shadow_entry#*:}"
shadow_password_field="${shadow_password_field%%:*}"

if [[ -z "${shadow_password_field}" || "${shadow_password_field}" == "!"* ]]; then
    log "Resetting ${USER_NAME} to an invalid but not fully locked password marker"
    usermod --password '*' "${USER_NAME}"
fi

log "Clearing account expiry for ${USER_NAME}"
chage --expiredate -1 "${USER_NAME}"

current_home="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
if [[ "${current_home}" != "${USER_HOME}" ]]; then
    log "Resetting home for ${USER_NAME} to ${USER_HOME}"
    usermod --home "${USER_HOME}" "${USER_NAME}"
fi

current_shell="$(getent passwd "${USER_NAME}" | cut -d: -f7)"
if [[ "${current_shell}" != "${USER_SHELL}" ]]; then
    log "Resetting shell for ${USER_NAME} to ${USER_SHELL}"
    usermod --shell "${USER_SHELL}" "${USER_NAME}"
fi

ensure_subid_entry /etc/subuid
ensure_subid_entry /etc/subgid
ensure_fcontext_rule "${BLACKBOX_CONFIG_FCONTEXT}"

if systemctl is-failed --quiet "user@${USER_UID}.service"; then
    log "Retrying user@${USER_UID}.service after account repair"
    systemctl reset-failed "user@${USER_UID}.service"
    systemctl start "user@${USER_UID}.service"
fi
