#!/usr/bin/env bash
# ABOUTME: Resolves and verifies the version inputs shared by local and CI builds.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
resolve_zfs_bin="${RESOLVE_ZFS_BIN:-${script_dir}/resolve-zfs-version.sh}"
query_kernel_bin="${QUERY_KERNEL_BIN:-${script_dir}/query-coreos-kernel.sh}"
skopeo_bin="${SKOPEO_BIN:-skopeo}"
github_output=""

if [[ "${1:-}" == "--github-output" ]]; then
    if (( $# < 2 )); then
        echo "--github-output requires a path" >&2
        exit 2
    fi
    github_output="$2"
    shift 2
fi
if (( $# > 1 )); then
    echo "usage: $0 [--github-output PATH] [ZFS_STREAM]" >&2
    exit 2
fi
zfs_stream="${1:-zfs-2.4}"

zfs_version="$("${resolve_zfs_bin}" "${zfs_stream}")"
kernel_version="$("${query_kernel_bin}")"

validate_build_input() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" || "${value}" == "null" ]]; then
        echo "Failed to resolve ${name}" >&2
        exit 1
    fi
    if [[ ! "${value}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        echo "Resolved ${name} contains unsupported characters: ${value}" >&2
        exit 1
    fi
}
validate_build_input "ZFS version" "${zfs_version}"
validate_build_input "kernel version" "${kernel_version}"

kmod_image="ghcr.io/samhclark/fedora-zfs-kmods:zfs-${zfs_version}_kernel-${kernel_version}"
echo "Checking availability: ${kmod_image}" >&2
if ! "${skopeo_bin}" inspect "docker://${kmod_image}" >/dev/null 2>&1; then
    echo "No prebuilt ZFS kmods found for this combination" >&2
    echo "  ZFS:    ${zfs_version}" >&2
    echo "  Kernel: ${kernel_version}" >&2
    echo "  Image:  ${kmod_image}" >&2
    exit 1
fi

if [[ -n "${github_output}" ]]; then
    {
        printf 'zfs-version=%s\n' "${zfs_version}"
        printf 'kernel-version=%s\n' "${kernel_version}"
        printf 'kmod-image=%s\n' "${kmod_image}"
    } >> "${github_output}"
else
    printf '%s\t%s\t%s\n' \
        "${zfs_version}" "${kernel_version}" "${kmod_image}"
fi
