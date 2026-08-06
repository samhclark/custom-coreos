#!/bin/bash
# ABOUTME: Builds the Linux 6.18 libkrun probe and exports it as a portable
# OCI archive for an operator-mediated NAS test.

set -euo pipefail

IMAGE="localhost/jellyfin-krun-kernel-prototype:6.18.42"
CONTEXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="${1:-/tmp/jellyfin-krun-kernel-prototype-6.18.42.oci.tar}"

podman build \
    --file "${CONTEXT_DIR}/Containerfile" \
    --tag "${IMAGE}" \
    "${CONTEXT_DIR}"

podman save \
    --format oci-archive \
    --output "${ARCHIVE}" \
    "${IMAGE}"

echo
echo "Prototype archive: ${ARCHIVE}"
sha256sum "${ARCHIVE}"
du -h "${ARCHIVE}"
