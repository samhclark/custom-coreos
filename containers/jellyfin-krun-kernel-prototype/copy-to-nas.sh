#!/bin/bash
# ABOUTME: Copies the already-built external-kernel OCI archive and its
# guarded operator runner to the NAS without executing anything remotely.

set -euo pipefail

DESTINATION="${1:-core@nas}"
ARCHIVE="${2:-/tmp/jellyfin-krun-kernel-prototype-6.18.42.oci.tar}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -r "${ARCHIVE}" ]]; then
    echo "Prototype archive is missing: ${ARCHIVE}" >&2
    echo "Build it first with ${SCRIPT_DIR}/build-and-export.sh" >&2
    exit 1
fi

rsync --archive --human-readable --progress \
    "${ARCHIVE}" \
    "${SCRIPT_DIR}/run-on-nas.sh" \
    "${DESTINATION}:/var/tmp/"

echo
echo "Copied only; nothing was executed on the NAS."
echo "After reviewing the runner, execute this yourself on the NAS:"
echo "  sudo /var/tmp/run-on-nas.sh"
