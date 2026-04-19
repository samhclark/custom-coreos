#!/bin/bash
# ABOUTME: Podman shell driver list script. Outputs one secret ID per line.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
podman_secret_store_context

shopt -s nullglob
for f in "${SECRET_STORE_DIR}"/*.cred; do
    basename "${f}" .cred
done
