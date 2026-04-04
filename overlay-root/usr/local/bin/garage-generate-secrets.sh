#!/bin/bash
# ABOUTME: Generates Garage API tokens and stores them as podman secrets.
# Uses the shell driver backed by age + age-plugin-tpm for encryption at rest.
# This script is idempotent - it only creates secrets that don't exist.

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

secret_exists() {
    podman secret inspect "$1" &>/dev/null
}

generate_token() {
    openssl rand -base64 32
}

# Generate RPC secret (required for Garage cluster communication, even single-node)
if secret_exists "garage-rpc-secret"; then
    log "garage-rpc-secret already exists, skipping"
else
    log "Generating garage-rpc-secret"
    openssl rand -hex 32 | podman secret create garage-rpc-secret -
fi

# Generate admin token
if secret_exists "garage-admin-token"; then
    log "garage-admin-token already exists, skipping"
else
    log "Generating garage-admin-token"
    generate_token | podman secret create garage-admin-token -
fi

# Generate metrics token
if secret_exists "garage-metrics-token"; then
    log "garage-metrics-token already exists, skipping"
else
    log "Generating garage-metrics-token"
    generate_token | podman secret create garage-metrics-token -
fi

log "Garage secrets ready"
