#!/bin/bash
# ABOUTME: Decrypts the image-shipped SOPS secrets file, distributes rootful
# Podman secrets, and writes per-service runtime files under /run/nas-secrets
# for rootless services (which must not use Podman Secret= with the shell
# driver; see docs/plan-sops-and-quadlet-generator.md Appendix D).

set -euo pipefail

SOPS_FILE="/usr/share/custom-coreos/secrets/secrets.sops.yaml"
ROOTFUL_MANIFEST="/usr/share/custom-coreos/secrets/rootful-secrets.json"
QUADLET_DIR="/usr/share/custom-coreos/quadlets"
AGE_CREDENTIAL="/var/lib/nas-secrets/age-key.cred"
STATE_DIR="/var/lib/nas-secrets"
STATE_FILE="${STATE_DIR}/distributed-state.json"
RUNTIME_DIR="/run/nas-secrets"

age_key_file=""
secrets_json_file=""
old_state_file=""
state_rows_file=""
new_state_file=""

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

    rm -f "${old_state_file}" "${state_rows_file}" "${new_state_file}"
}
trap cleanup EXIT

require_file() {
    if [[ ! -f "$1" ]]; then
        log "ERROR: Missing required file: $1"
        exit 1
    fi
}

read_rootful_secrets() {
    jq -r '
        if (.secrets | type) != "array" then
            error("rootful secrets manifest must contain a secrets array")
        else
            .secrets[]
            | if type == "string" then
                .
              else
                error("rootful secrets manifest entries must be strings")
              end
        end
    ' "${ROOTFUL_MANIFEST}"
}

# Emits one row per declared rootless secret:
#   <service>\t<username>\t<secret-name>
read_quadlet_secret_rows() {
    local file
    local line
    local section
    local service
    local username

    shopt -s nullglob
    local files=("${QUADLET_DIR}"/*.toml)
    shopt -u nullglob

    for file in "${files[@]}"; do
        section=""
        service=""
        username=""

        while IFS= read -r line; do
            line="${line%%#*}"

            if [[ "${line}" =~ ^[[:space:]]*\[service\][[:space:]]*$ ]]; then
                section="service"
                continue
            fi

            if [[ "${line}" =~ ^[[:space:]]*\[host\][[:space:]]*$ ]]; then
                section="host"
                continue
            fi

            if [[ "${line}" =~ ^[[:space:]]*\[\[container\.secrets\]\][[:space:]]*$ ]]; then
                section="container_secret"
                continue
            fi

            if [[ "${line}" =~ ^[[:space:]]*\[ ]]; then
                section=""
                continue
            fi

            if [[ "${section}" == "service" && "${line}" =~ ^[[:space:]]*name[[:space:]]*=[[:space:]]*\"([a-z0-9-]+)\" ]]; then
                service="${BASH_REMATCH[1]}"
                continue
            fi

            if [[ "${section}" == "host" && "${line}" =~ ^[[:space:]]*username[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                username="${BASH_REMATCH[1]}"
                continue
            fi

            if [[ "${section}" == "container_secret" && "${line}" =~ ^[[:space:]]*name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                if [[ -z "${service}" || -z "${username}" ]]; then
                    log "ERROR: ${file} declares a secret before [service].name and [host].username"
                    exit 1
                fi
                printf '%s\t%s\t%s\n' "${service}" "${username}" "${BASH_REMATCH[1]}"
            fi
        done < "${file}"
    done
}

secret_exists() {
    local secret="$1"

    podman secret inspect "${secret}" >/dev/null 2>&1
}

secret_value() {
    local secret="$1"

    jq -r --arg name "${secret}" '.[$name]' "${secrets_json_file}"
}

secret_hash() {
    local secret="$1"
    local value

    value="$(secret_value "${secret}")"
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
}

replace_secret() {
    local secret="$1"
    local value

    if secret_exists "${secret}"; then
        podman secret rm "${secret}" >/dev/null
    fi

    value="$(secret_value "${secret}")"
    printf '%s' "${value}" | podman secret create "${secret}" - >/dev/null
}

delete_secret() {
    local secret="$1"

    if secret_exists "${secret}"; then
        podman secret rm "${secret}" >/dev/null
    fi
}

# Writes /run/nas-secrets/<service>/<secret> as 0400 <user>:<user> under a
# 0710 root:<user> directory. Consuming quadlets mount the file read-only
# with a ':Z' relabel (validated on the NAS: rootless podman can relabel
# tmpfs files under /run to container_file_t).
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

install -d -m 0700 "${STATE_DIR}"
install -d -m 0711 -o root -g root "${RUNTIME_DIR}"
require_file "${SOPS_FILE}"
require_file "${ROOTFUL_MANIFEST}"
require_file "${AGE_CREDENTIAL}"

age_key_file="$(mktemp "${RUNTIME_DIR}/.age-key.XXXXXX")"
secrets_json_file="$(mktemp "${RUNTIME_DIR}/.secrets.XXXXXX.json")"
old_state_file="$(mktemp "${RUNTIME_DIR}/.old-state.XXXXXX.json")"
state_rows_file="$(mktemp "${RUNTIME_DIR}/.state-rows.XXXXXX.tsv")"
new_state_file="$(mktemp "${STATE_DIR}/distributed-state.XXXXXX.json")"

chmod 0600 "${age_key_file}" "${secrets_json_file}" "${old_state_file}" "${state_rows_file}" "${new_state_file}"

log "Decrypting SOPS age key"
systemd-creds decrypt --name=age-key "${AGE_CREDENTIAL}" "${age_key_file}"

log "Decrypting SOPS secrets"
SOPS_AGE_KEY_FILE="${age_key_file}" \
    sops --decrypt --output-type json "${SOPS_FILE}" > "${secrets_json_file}"

if [[ -f "${STATE_FILE}" ]]; then
    if jq empty "${STATE_FILE}" >/dev/null 2>&1; then
        cp "${STATE_FILE}" "${old_state_file}"
    else
        log "WARNING: Existing state file is invalid JSON; treating all secrets as changed"
        printf '{}\n' > "${old_state_file}"
    fi
else
    printf '{}\n' > "${old_state_file}"
fi

require_sops_secret() {
    local consumer="$1"
    local secret="$2"

    if ! jq -e --arg name "${secret}" 'has($name) and (.[$name] | type == "string")' "${secrets_json_file}" >/dev/null; then
        log "ERROR: Secret '${secret}' is declared for ${consumer} but is missing from ${SOPS_FILE}"
        missing_secrets=1
        return 1
    fi
}

declare -A desired_hashes
missing_secrets=0

while IFS= read -r secret; do
    if require_sops_secret "root" "${secret}"; then
        desired_hashes["${secret}"]="$(secret_hash "${secret}")"
    fi
done < <(read_rootful_secrets)

runtime_rows="$(read_quadlet_secret_rows)"

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

# Delete rootful Podman secrets that are no longer declared. Older state
# files may contain non-root keys from a retired design; only 'root' entries
# correspond to Podman secrets now.
while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue

    if [[ -z "${desired_hashes[${secret}]+set}" ]]; then
        log "Deleting no-longer-declared Podman secret '${secret}'"
        delete_secret "${secret}"
    fi
done < <(jq -r '.root // {} | keys[]' "${old_state_file}")

while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue

    hash="${desired_hashes[${secret}]}"
    old_hash="$(jq -r --arg secret "${secret}" '.root[$secret] // ""' "${old_state_file}")"

    if [[ "${old_hash}" == "${hash}" ]] && secret_exists "${secret}"; then
        log "Podman secret '${secret}' is up to date"
    else
        log "Creating or updating Podman secret '${secret}'"
        replace_secret "${secret}"
    fi
done < <(printf '%s\n' "${!desired_hashes[@]}" | sort)

# Rebuild the rootless runtime file tree from scratch on every run: /run is
# tmpfs, so never skip these based on saved state. Only directories are
# managed service dirs; the dotfiles in ${RUNTIME_DIR} are this script's
# own temp files.
find "${RUNTIME_DIR}" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

while IFS=$'\t' read -r service user secret; do
    [[ -z "${service}" ]] && continue

    log "Writing runtime secret '${secret}' for service '${service}' (${user})"
    write_runtime_secret "${service}" "${user}" "${secret}"
done <<< "${runtime_rows}"

: > "${state_rows_file}"
while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue

    printf 'root\t%s\t%s\n' "${secret}" "${desired_hashes[${secret}]}" >> "${state_rows_file}"
done < <(printf '%s\n' "${!desired_hashes[@]}" | sort)

jq -Rn '
  reduce inputs as $line ({};
    ($line | split("\t")) as $fields |
    .[$fields[0]][$fields[1]] = $fields[2]
  )
' < "${state_rows_file}" > "${new_state_file}"
chmod 0600 "${new_state_file}"
mv -f "${new_state_file}" "${STATE_FILE}"
new_state_file=""

log "SOPS secrets distributed successfully"
