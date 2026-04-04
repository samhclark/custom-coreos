#!/bin/bash
# ABOUTME: Podman shell driver store script. Encrypts secret data from stdin
# with age using the TPM-sealed identity's recipient and writes to the store.

set -euo pipefail

IDENTITY_FILE="/var/lib/age-tpm/identity.txt"
STORE_DIR="/var/lib/podman-secrets"

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

RECIPIENT="$(age-plugin-tpm -y "$IDENTITY_FILE")"
if [[ -z "$RECIPIENT" ]]; then
    echo "ERROR: Could not extract recipient from $IDENTITY_FILE" >&2
    exit 1
fi

age -r "$RECIPIENT" -o "${STORE_DIR}/${SECRET_ID}.age"
