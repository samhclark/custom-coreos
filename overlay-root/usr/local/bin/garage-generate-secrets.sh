#!/bin/bash
# Generates Garage API tokens if they don't already exist
#
# This script is idempotent - it only creates secrets that don't exist.
# Secrets are stored on the root filesystem (not ZFS) so they're available
# before ZFS datasets are mounted.

set -euo pipefail

SECRETS_DIR="/var/lib/garage"
RPC_SECRET_FILE="${SECRETS_DIR}/rpc_secret"
ADMIN_TOKEN_FILE="${SECRETS_DIR}/admin_token"
METRICS_TOKEN_FILE="${SECRETS_DIR}/metrics_token"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

generate_token() {
    openssl rand -base64 32
}

# Create secrets directory if it doesn't exist (should be created by tmpfiles)
if [[ ! -d "${SECRETS_DIR}" ]]; then
    log "Creating ${SECRETS_DIR}"
    mkdir -p "${SECRETS_DIR}"
fi

# Generate RPC secret (required for Garage cluster communication, even single-node)
if [[ -f "${RPC_SECRET_FILE}" ]]; then
    log "RPC secret already exists, skipping"
else
    log "Generating RPC secret"
    openssl rand -hex 32 > "${RPC_SECRET_FILE}"
    chmod 600 "${RPC_SECRET_FILE}"
fi

# Generate admin token
if [[ -f "${ADMIN_TOKEN_FILE}" ]]; then
    log "Admin token already exists, skipping"
else
    log "Generating admin token"
    generate_token > "${ADMIN_TOKEN_FILE}"
    chmod 600 "${ADMIN_TOKEN_FILE}"
fi

# Generate metrics token
if [[ -f "${METRICS_TOKEN_FILE}" ]]; then
    log "Metrics token already exists, skipping"
else
    log "Generating metrics token"
    generate_token > "${METRICS_TOKEN_FILE}"
    chmod 600 "${METRICS_TOKEN_FILE}"
fi

log "Garage secrets ready"
