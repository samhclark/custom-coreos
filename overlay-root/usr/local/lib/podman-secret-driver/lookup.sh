#!/bin/bash
# ABOUTME: Podman shell driver lookup script. Decrypts the named secret using
# systemd-creds and writes plaintext to stdout.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    STORE_DIR="/var/lib/podman-secrets"
    CREDS_MODE=()
else
    STORE_DIR="/var/lib/podman-secrets/$(id -un)"
    CREDS_MODE=(--user)
fi

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

SECRET_FILE="${STORE_DIR}/${SECRET_ID}.cred"

if [[ ! -f "${SECRET_FILE}" ]]; then
    echo "ERROR: Secret not found: ${SECRET_ID}" >&2
    exit 1
fi

systemd-creds decrypt "${CREDS_MODE[@]}" --name "${SECRET_ID}.cred" "${SECRET_FILE}" -
