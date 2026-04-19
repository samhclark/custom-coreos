#!/bin/bash
# ABOUTME: Podman shell driver delete script. Removes the encrypted secret file.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
podman_secret_store_context

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

SECRET_FILE="${SECRET_STORE_DIR}/${SECRET_ID}.cred"

if [[ ! -f "${SECRET_FILE}" ]]; then
    echo "ERROR: Secret not found: ${SECRET_ID}" >&2
    exit 1
fi

rm -f "${SECRET_FILE}"
