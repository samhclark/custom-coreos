#!/bin/bash
# ABOUTME: Podman shell driver lookup script. Decrypts the named secret
# using the TPM-sealed age identity and writes plaintext to stdout.

set -euo pipefail

IDENTITY_FILE="/var/lib/age-tpm/identity.txt"
STORE_DIR="/var/lib/podman-secrets"

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

SECRET_FILE="${STORE_DIR}/${SECRET_ID}.age"

if [[ ! -f "$SECRET_FILE" ]]; then
    echo "ERROR: Secret not found: ${SECRET_ID}" >&2
    exit 1
fi

age -d -i "$IDENTITY_FILE" "$SECRET_FILE"
