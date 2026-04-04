#!/bin/bash
# ABOUTME: Podman shell driver delete script. Removes the encrypted secret file.

set -euo pipefail

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

rm -f "$SECRET_FILE"
