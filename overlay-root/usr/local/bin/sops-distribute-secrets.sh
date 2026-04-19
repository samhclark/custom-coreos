#!/bin/bash
# ABOUTME: Decrypts the image-shipped SOPS secrets file and distributes
# secrets into rootful and rootless Podman secret stores.

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

read_quadlet_secret_rows() {
    local file
    local line
    local section
    local username
    local uid

    shopt -s nullglob
    local files=("${QUADLET_DIR}"/*.toml)
    shopt -u nullglob

    for file in "${files[@]}"; do
        section=""
        username=""
        uid=""

        while IFS= read -r line; do
            line="${line%%#*}"

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

            if [[ "${section}" == "host" && "${line}" =~ ^[[:space:]]*username[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                username="${BASH_REMATCH[1]}"
                continue
            fi

            if [[ "${section}" == "host" && "${line}" =~ ^[[:space:]]*uid[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                uid="${BASH_REMATCH[1]}"
                continue
            fi

            if [[ "${section}" == "container_secret" && "${line}" =~ ^[[:space:]]*name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                if [[ -z "${username}" ]]; then
                    log "ERROR: ${file} declares a secret before [host].username"
                    exit 1
                fi
                printf '%s\t%s\t%s\n' "${username}" "${uid}" "${BASH_REMATCH[1]}"
            fi
        done < "${file}"
    done
}

podman_home_for_user() {
    local user="$1"
    local home

    home="$(getent passwd "${user}" | cut -d: -f6 || true)"
    if [[ -z "${home}" ]]; then
        home="/var/home/${user}"
    fi

    printf '%s\n' "${home}"
}

run_podman_as() {
    local user="$1"
    shift

    if [[ "${user}" == "root" ]]; then
        podman "$@"
        return
    fi

    local home
    home="$(podman_home_for_user "${user}")"
    sudo -u "${user}" env HOME="${home}" bash -c 'cd "$HOME"; exec podman "$@"' podman "$@"
}

secret_exists() {
    local user="$1"
    local secret="$2"

    run_podman_as "${user}" secret inspect "${secret}" >/dev/null 2>&1
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

ensure_rootless_store() {
    local user="$1"

    if [[ "${user}" == "root" ]]; then
        return
    fi

    install -d -m 0700 -o "${user}" -g "${user}" "/var/lib/podman-secrets/${user}"
}

replace_secret() {
    local user="$1"
    local secret="$2"
    local value

    ensure_rootless_store "${user}"

    if secret_exists "${user}" "${secret}"; then
        run_podman_as "${user}" secret rm "${secret}" >/dev/null
    fi

    value="$(secret_value "${secret}")"
    printf '%s' "${value}" | run_podman_as "${user}" secret create "${secret}" - >/dev/null
}

delete_secret() {
    local user="$1"
    local secret="$2"

    if secret_exists "${user}" "${secret}"; then
        run_podman_as "${user}" secret rm "${secret}" >/dev/null
    fi
}

install -d -m 0700 "${STATE_DIR}" "${RUNTIME_DIR}"
require_file "${SOPS_FILE}"
require_file "${ROOTFUL_MANIFEST}"
require_file "${AGE_CREDENTIAL}"

age_key_file="$(mktemp "${RUNTIME_DIR}/age-key.XXXXXX")"
secrets_json_file="$(mktemp "${RUNTIME_DIR}/secrets.XXXXXX.json")"
old_state_file="$(mktemp "${RUNTIME_DIR}/old-state.XXXXXX.json")"
state_rows_file="$(mktemp "${RUNTIME_DIR}/state-rows.XXXXXX.tsv")"
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

declare -A desired_hashes
declare -A user_uids
missing_secrets=0

add_desired_secret() {
    local user="$1"
    local uid="$2"
    local secret="$3"
    local hash

    if ! jq -e --arg name "${secret}" 'has($name) and (.[$name] | type == "string")' "${secrets_json_file}" >/dev/null; then
        log "ERROR: Secret '${secret}' is declared for ${user} but is missing from ${SOPS_FILE}"
        missing_secrets=1
        return
    fi

    hash="$(secret_hash "${secret}")"
    desired_hashes["${user}|${secret}"]="${hash}"

    if [[ "${user}" != "root" ]]; then
        user_uids["${user}"]="${uid}"
    fi
}

while IFS= read -r secret; do
    add_desired_secret "root" "" "${secret}"
done < <(read_rootful_secrets)

while IFS=$'\t' read -r user uid secret; do
    add_desired_secret "${user}" "${uid}" "${secret}"
done < <(read_quadlet_secret_rows)

if [[ "${missing_secrets}" -ne 0 ]]; then
    exit 1
fi

while IFS=$'\t' read -r user secret; do
    [[ -z "${user}" || -z "${secret}" ]] && continue

    if [[ -z "${desired_hashes[${user}|${secret}]+set}" ]]; then
        log "Deleting no-longer-declared Podman secret '${secret}' for ${user}"
        delete_secret "${user}" "${secret}"
    fi
done < <(jq -r 'to_entries[] | .key as $user | .value | keys[] | [$user, .] | @tsv' "${old_state_file}")

while IFS= read -r key; do
    [[ -z "${key}" ]] && continue

    user="${key%%|*}"
    secret="${key#*|}"
    hash="${desired_hashes[${key}]}"
    old_hash="$(jq -r --arg user "${user}" --arg secret "${secret}" '.[$user][$secret] // ""' "${old_state_file}")"

    if [[ "${old_hash}" == "${hash}" ]] && secret_exists "${user}" "${secret}"; then
        log "Podman secret '${secret}' for ${user} is up to date"
    else
        log "Creating or updating Podman secret '${secret}' for ${user}"
        replace_secret "${user}" "${secret}"
    fi
done < <(printf '%s\n' "${!desired_hashes[@]}" | sort)

: > "${state_rows_file}"
while IFS= read -r key; do
    [[ -z "${key}" ]] && continue

    user="${key%%|*}"
    secret="${key#*|}"
    printf '%s\t%s\t%s\n' "${user}" "${secret}" "${desired_hashes[${key}]}" >> "${state_rows_file}"
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
