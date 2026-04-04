#!/bin/bash
# ABOUTME: Generates Alertmanager config by substituting Pushover secrets into the template.
# Reads secrets from /var/lib/alertmanager/ and writes the final config there.

set -euo pipefail

SECRETS_DIR="/var/lib/alertmanager"
TEMPLATE="/etc/alertmanager/alertmanager.yml.template"
OUTPUT="${SECRETS_DIR}/alertmanager.yml"

USER_KEY_FILE="${SECRETS_DIR}/pushover_user_key"
API_TOKEN_FILE="${SECRETS_DIR}/pushover_api_token"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [[ ! -f "${USER_KEY_FILE}" ]]; then
    log "ERROR: ${USER_KEY_FILE} not found. Create this file with your Pushover user key."
    exit 1
fi

if [[ ! -f "${API_TOKEN_FILE}" ]]; then
    log "ERROR: ${API_TOKEN_FILE} not found. Create this file with your Pushover API token."
    exit 1
fi

user_key="$(cat "${USER_KEY_FILE}" | tr -d '[:space:]')"
api_token="$(cat "${API_TOKEN_FILE}" | tr -d '[:space:]')"

if [[ -z "${user_key}" || -z "${api_token}" ]]; then
    log "ERROR: Pushover secrets are empty"
    exit 1
fi

log "Generating Alertmanager config from template"
sed \
    -e "s/__PUSHOVER_USER_KEY__/${user_key}/" \
    -e "s/__PUSHOVER_API_TOKEN__/${api_token}/" \
    "${TEMPLATE}" > "${OUTPUT}"
chmod 600 "${OUTPUT}"

log "Alertmanager config written to ${OUTPUT}"
