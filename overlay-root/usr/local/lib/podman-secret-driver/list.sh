#!/bin/bash
# ABOUTME: Podman shell driver list script. Outputs one secret ID per line.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    STORE_DIR="/var/lib/podman-secrets"
else
    STORE_DIR="/var/lib/podman-secrets/$(id -un)"
fi

shopt -s nullglob
for f in "${STORE_DIR}"/*.cred; do
    basename "${f}" .cred
done
