#!/usr/bin/env bash
# ABOUTME: Boots one supplied QCOW in an isolated, transient, networkless VM.
set -euo pipefail

readonly qcow_argument="${1:?usage: run-vm-smoke.sh /absolute/path/image.qcow2}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly repo
readonly container_cli="${CONTAINER_CLI:-podman}"
readonly butane_image="${BUTANE_IMAGE:?BUTANE_IMAGE is required}"
readonly qemu="${QEMU_BIN:-qemu-system-x86_64}"
readonly qemu_img="${QEMU_IMG_BIN:-qemu-img}"
readonly jq="${JQ_BIN:-jq}"
readonly timeout_bin="${TIMEOUT_BIN:-timeout}"
readonly ovmf="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"

[[ "${qcow_argument}" == /* ]] || {
    printf 'QCOW must be an absolute path\n' >&2
    exit 2
}
[[ -f "${qcow_argument}" && ! -L "${qcow_argument}" ]] || {
    printf 'QCOW must be a regular, non-symlink file: %s\n' "${qcow_argument}" >&2
    exit 2
}
[[ -r "${ovmf}" && -f "${ovmf}" ]] || {
    printf 'OVMF firmware is not readable: %s\n' "${ovmf}" >&2
    exit 2
}
qcow="$(realpath -- "${qcow_argument}")"
readonly qcow

# QEMU's -drive and -fw_cfg options use commas as field separators. Keeping the
# only caller-controlled path out of that grammar is clearer than maintaining a
# second escaping language in this safety-sensitive runner.
[[ "${repo}${qcow}" != *','* && "${repo}${qcow}" != *$'\n'* ]] || {
    printf 'Repository and QCOW paths must not contain commas or newlines\n' >&2
    exit 2
}

if ! image_info="$("${qemu_img}" info --output=json "${qcow}")"; then
    printf 'Could not inspect QCOW2 image: %s\n' "${qcow}" >&2
    exit 2
fi
readonly image_info
printf '%s\n' "${image_info}" |
    "${jq}" --exit-status \
        '.format == "qcow2"
         and (has("backing-filename") | not)
         and (has("full-backing-filename") | not)
         and ((.["format-specific"].data["data-file"]? // null) == null)' \
        >/dev/null || {
            printf 'QCOW must be standalone, without backing or external data files: %s\n' \
                "${qcow}" >&2
            exit 2
        }
"${qemu_img}" check --quiet -f qcow2 "${qcow}" || {
    printf 'QCOW integrity check failed: %s\n' "${qcow}" >&2
    exit 2
}

mkdir -p -- "${repo}/build/vm-smoke"
run_dir="$(mktemp -d "${repo}/build/vm-smoke/run.XXXXXX")"
readonly run_dir
readonly ignition="${run_dir}/config.ign"
readonly serial_log="${run_dir}/serial.log"
readonly normalized_serial="${run_dir}/serial.normalized.log"
readonly qemu_log="${run_dir}/qemu.log"

"${container_cli}" run --rm --interactive --network=none --pull=never \
    --read-only --cap-drop=all \
    --security-opt=no-new-privileges \
    "${butane_image}" --strict < "${repo}/tests/vm-smoke.bu" > "${ignition}"

before_hash="$(sha256sum -- "${qcow}")"
readonly before_hash
set +e
TMPDIR="${run_dir}" "${timeout_bin}" \
    --foreground --signal=TERM --kill-after=10s 180s \
    "${qemu}" \
    -name custom-coreos-vm-smoke \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 2 \
    -m 2048 \
    -nodefaults \
    -display none \
    -monitor none \
    -serial "file:${serial_log}" \
    -bios "${ovmf}" \
    -no-reboot \
    -snapshot \
    -nic none \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -drive "if=none,id=osdisk,file=${qcow},format=qcow2,cache=none" \
    -device virtio-blk-pci,drive=osdisk,bootindex=1 \
    -fw_cfg "name=opt/com.coreos/config,file=${ignition}" \
    >"${qemu_log}" 2>&1
qemu_status="$?"
set -e

after_hash="$(sha256sum -- "${qcow}")"
readonly after_hash
[[ "${before_hash}" == "${after_hash}" ]] || {
    printf 'QCOW changed despite the transient VM contract: %s; artifacts: %s\n' \
        "${qcow}" "${run_dir}" >&2
    exit 1
}

if [[ -f "${serial_log}" ]]; then
    tr -d '\r' < "${serial_log}" > "${normalized_serial}"
    sed -n '/CUSTOM_COREOS_VM_SMOKE_BEGIN/,$p' "${normalized_serial}"
fi
if [[ "${qemu_status}" -ne 0 ]]; then
    printf 'QEMU failed with status %s; artifacts: %s\n' \
        "${qemu_status}" "${run_dir}" >&2
    exit "${qemu_status}"
fi
if grep -Fq 'CUSTOM_COREOS_VM_SMOKE_FAIL' "${normalized_serial}"; then
    printf 'Guest reported a failed assertion; artifacts: %s\n' "${run_dir}" >&2
    exit 1
fi
grep -Fqx 'CUSTOM_COREOS_VM_SMOKE_PASS' "${normalized_serial}" || {
    printf 'Guest did not report a pass sentinel; artifacts: %s\n' "${run_dir}" >&2
    exit 1
}
printf 'VM smoke passed; artifacts retained at %s\n' "${run_dir}"
