#!/bin/bash
# ABOUTME: Decrypts the image-shipped SOPS secrets file and writes declared
# runtime files under /run/nas-secrets for service and host consumers.

set -euo pipefail

SOPS_FILE="/usr/share/nas/secrets/secrets.sops.yaml"
SECRET_MANIFEST="/usr/share/nas/fleet/secrets.tsv"
AGE_CREDENTIAL="/var/lib/nas-secrets/age-key.cred"
RUNTIME_DIR="/run/nas-secrets"

age_key_file=""
secrets_json_file=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    set +e

    if [[ -n "${age_key_file}" && -f "${age_key_file}" ]]; then
        shred -u "${age_key_file}"
    fi

    if [[ -n "${secrets_json_file}" && -f "${secrets_json_file}" ]]; then
        shred -u "${secrets_json_file}"
    fi
}
trap cleanup EXIT

require_file() {
    if [[ ! -f "$1" ]]; then
        log "ERROR: Missing required file: $1"
        exit 1
    fi
}

secret_value() {
    local secret="$1"

    jq -r --arg name "${secret}" '.[$name]' "${secrets_json_file}"
}

# Writes /run/nas-secrets/<consumer>/<secret> as 0400 <user>:<user> under a
# 0710 root:<user> directory. Root-owned consumers therefore receive root:root
# files. Rootless quadlets mount their files read-only with a ':Z' relabel
# (validated on the NAS: rootless podman can relabel tmpfs files under /run to
# container_file_t).
write_runtime_secret() {
    local service="$1"
    local user="$2"
    local secret="$3"
    local dir="${RUNTIME_DIR}/${service}"
    local tmp
    local value

    install -d -m 0710 -o root -g "${user}" "${dir}"
    tmp="$(mktemp "${dir}/.tmp.XXXXXX")"
    value="$(secret_value "${secret}")"
    printf '%s' "${value}" > "${tmp}"
    chown "${user}:${user}" "${tmp}"
    chmod 0400 "${tmp}"
    mv -f "${tmp}" "${dir}/${secret}"
}

install -d -m 0711 -o root -g root "${RUNTIME_DIR}"
require_file "${SOPS_FILE}"
require_file "${SECRET_MANIFEST}"
require_file "${AGE_CREDENTIAL}"

age_key_file="$(mktemp "${RUNTIME_DIR}/.age-key.XXXXXX")"
secrets_json_file="$(mktemp "${RUNTIME_DIR}/.secrets.XXXXXX.json")"

chmod 0600 "${age_key_file}" "${secrets_json_file}"

log "Decrypting SOPS age key"
systemd-creds decrypt --name=age-key "${AGE_CREDENTIAL}" "${age_key_file}"

log "Decrypting SOPS secrets"
SOPS_AGE_KEY_FILE="${age_key_file}" \
    sops --decrypt --output-type json "${SOPS_FILE}" > "${secrets_json_file}"

require_sops_secret() {
    local consumer="$1"
    local secret="$2"

    if ! jq -e --arg name "${secret}" 'has($name) and (.[$name] | type == "string")' "${secrets_json_file}" >/dev/null; then
        log "ERROR: Secret '${secret}' is declared for ${consumer} but is missing from ${SOPS_FILE}"
        missing_secrets=1
        return 1
    fi
}

missing_secrets=0

runtime_rows="$(awk '!/^#/' "${SECRET_MANIFEST}")"

while IFS=$'\t' read -r service user secret; do
    [[ -z "${service}" ]] && continue

    require_sops_secret "${service}" "${secret}" || continue

    if ! getent passwd "${user}" >/dev/null; then
        log "ERROR: Secret '${secret}' for service '${service}' declares unknown user '${user}'"
        missing_secrets=1
    fi
done <<< "${runtime_rows}"

if [[ "${missing_secrets}" -ne 0 ]]; then
    exit 1
fi

# Rebuild the runtime secret file tree from scratch on every run: /run is
# tmpfs, so never skip these based on saved state. Only directories are
# managed consumer dirs; the dotfiles in ${RUNTIME_DIR} are this script's own
# temp files.
find "${RUNTIME_DIR}" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

while IFS=$'\t' read -r service user secret; do
    [[ -z "${service}" ]] && continue

    log "Writing runtime secret '${secret}' for service '${service}' (${user})"
    write_runtime_secret "${service}" "${user}" "${secret}"
done <<< "${runtime_rows}"

log "SOPS secrets distributed successfully"
