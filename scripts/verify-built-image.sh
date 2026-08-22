#!/usr/bin/env bash
# ABOUTME: Verifies the exact locally built bootc image without host access or networking.
set -euo pipefail

readonly container_cli="${CONTAINER_CLI:-podman}"
readonly image="${1:?usage: verify-built-image.sh IMAGE}"
contract="$(dirname "${BASH_SOURCE[0]}")/../tests/image-contract.sh"
readonly contract

inspect_label() {
    local label="$1"
    "${container_cli}" image inspect \
        --format "{{ index .Config.Labels \"${label}\" }}" \
        "${image}"
}

kernel_version="$(inspect_label nas.bootc.kernel-version)"
readonly kernel_version
zfs_version="$(inspect_label nas.bootc.zfs-version)"
readonly zfs_version

for value in "${kernel_version}" "${zfs_version}"; do
    if [[ -z "${value}" || "${value}" == "<no value>" ]]; then
        printf 'required image version label is missing from %s\n' "${image}" >&2
        exit 1
    fi
done

"${container_cli}" run \
    --rm \
    --network=none \
    --pull=never \
    --read-only \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --entrypoint=/bin/bash \
    "${image}" -s -- "${kernel_version}" "${zfs_version}" < "${contract}"
