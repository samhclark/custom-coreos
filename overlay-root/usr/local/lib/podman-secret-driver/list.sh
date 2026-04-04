#!/bin/bash
# ABOUTME: Podman shell driver list script. Outputs one secret ID per line.

set -euo pipefail

STORE_DIR="/var/lib/podman-secrets"

shopt -s nullglob
for f in "${STORE_DIR}"/*.age; do
    basename "$f" .age
done
