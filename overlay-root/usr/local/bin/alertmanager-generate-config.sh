#!/bin/bash
# ABOUTME: Generates Alertmanager config by substituting Pushover secrets into the template.
# Reads secrets from the podman secret shell driver (age + TPM encrypted).

set -euo pipefail

LOOKUP="/usr/local/lib/podman-secret-driver/lookup.sh"
TEMPLATE="/etc/alertmanager/alertmanager.yml.template"
OUTPUT="/var/lib/alertmanager/alertmanager.yml"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

user_key="$(SECRET_ID=pushover-user-key "$LOOKUP" | tr -d '[:space:]')"
api_token="$(SECRET_ID=pushover-api-token "$LOOKUP" | tr -d '[:space:]')"

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
