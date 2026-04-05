#!/bin/bash
# ABOUTME: Generates Alertmanager config by substituting Pushover secrets into the template.
# Reads secrets from the podman secret shell driver (age + TPM encrypted).

set -euo pipefail

TEMPLATE="/etc/alertmanager/alertmanager.yml.template"
OUTPUT="/var/lib/alertmanager/alertmanager.yml"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

user_key="$(nas-secrets show pushover-user-key | tr -d '[:space:]')"
api_token="$(nas-secrets show pushover-api-token | tr -d '[:space:]')"

if [[ -z "${user_key}" || -z "${api_token}" ]]; then
    log "ERROR: Pushover secrets are empty or missing"
    exit 1
fi

log "Generating Alertmanager config from template"
sed \
    -e "s/__PUSHOVER_USER_KEY__/${user_key}/" \
    -e "s/__PUSHOVER_API_TOKEN__/${api_token}/" \
    "${TEMPLATE}" > "${OUTPUT}"
chmod 600 "${OUTPUT}"

log "Alertmanager config written to ${OUTPUT}"
