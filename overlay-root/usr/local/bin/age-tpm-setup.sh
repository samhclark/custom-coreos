#!/bin/bash
# ABOUTME: Creates an age-plugin-tpm identity sealed to the local TPM.
# Used by the podman secret shell driver to encrypt/decrypt secrets at rest.
# The identity persists in /var across bootc upgrades.

set -euo pipefail

IDENTITY_DIR="/var/lib/age-tpm"
IDENTITY_FILE="${IDENTITY_DIR}/identity.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [[ -f "${IDENTITY_FILE}" ]]; then
    log "TPM identity already exists at ${IDENTITY_FILE}, skipping"
    exit 0
fi

# Directory should exist from tmpfiles.d, but ensure it
if [[ ! -d "${IDENTITY_DIR}" ]]; then
    mkdir -p "${IDENTITY_DIR}"
    chmod 0700 "${IDENTITY_DIR}"
fi

log "Generating new age-plugin-tpm identity"
age-plugin-tpm --generate -o "${IDENTITY_FILE}"
chmod 0600 "${IDENTITY_FILE}"

log "TPM identity created at ${IDENTITY_FILE}"
