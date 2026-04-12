#!/bin/bash
# ABOUTME: Repairs Podman secret backing files that were encrypted with a
# mktemp-derived embedded credential name instead of the final SECRET_ID.cred
# filename expected by the shell secret driver.

set -euo pipefail

STORE_DIR="/var/lib/podman-secrets"
DRY_RUN=false
REPAIRED=0
SKIPPED=0
FAILED=0

usage() {
    cat <<'USAGE'
Usage: sudo repair-podman-secret-cred-names.sh [--dry-run]

Repairs .cred files created by the initial systemd-creds Podman shell driver
implementation, which embedded a temporary filename such as:

  SECRET_ID.ABC123.cred

instead of the final on-disk filename:

  SECRET_ID.cred

Options:
  --dry-run   Report which files would be repaired without changing them
  -h, --help  Show this help
USAGE
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail_file() {
    log "FAILED: $1"
    FAILED=$((FAILED + 1))
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root so it can read and rewrite the rootful Podman secret store." >&2
    exit 1
fi

for cmd in podman systemd-creds mktemp sed grep; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "Missing required command: ${cmd}" >&2
        exit 1
    }
done

shopt -s nullglob
files=("${STORE_DIR}"/*.cred)

if [[ "${#files[@]}" -eq 0 ]]; then
    log "No .cred files found in ${STORE_DIR}"
    exit 0
fi

for file in "${files[@]}"; do
    id="$(basename "${file}" .cred)"
    expected_name="${id}.cred"
    secret_name="$(podman secret inspect "${id}" --format '{{.Spec.Name}}' 2>/dev/null || true)"
    label="${id}"
    if [[ -n "${secret_name}" ]]; then
        label="${secret_name} (${id})"
    fi

    if systemd-creds decrypt --name "${expected_name}" "${file}" - >/dev/null 2>&1; then
        log "OK: ${label}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    err="$(systemd-creds decrypt --name "${expected_name}" "${file}" - 2>&1 >/dev/null || true)"
    embedded_name="$(printf '%s\n' "${err}" | sed -n "s/^Embedded credential name '\\([^']\\+\\)' does not match filename '.*', refusing\\.$/\\1/p" | head -n1)"

    if [[ -z "${embedded_name}" ]]; then
        fail_file "${label}: could not determine embedded credential name (${err:-unknown error})"
        continue
    fi

    if [[ ! "${embedded_name}" =~ ^${id}\.[A-Za-z0-9]{6}\.cred$ ]]; then
        fail_file "${label}: embedded name '${embedded_name}' does not match the known broken mktemp pattern"
        continue
    fi

    if ${DRY_RUN}; then
        log "WOULD REPAIR: ${label} (${embedded_name} -> ${expected_name})"
        REPAIRED=$((REPAIRED + 1))
        continue
    fi

    tmp="$(mktemp "${STORE_DIR}/${id}.repair.XXXXXX")"
    if ! systemd-creds decrypt --name "${embedded_name}" "${file}" - \
        | systemd-creds encrypt --with-key=tpm2+host --name "${expected_name}" - "${tmp}" >/dev/null; then
        rm -f "${tmp}"
        fail_file "${label}: failed to re-encrypt with corrected name"
        continue
    fi

    chmod 0600 "${tmp}"

    if ! systemd-creds decrypt --name "${expected_name}" "${tmp}" - >/dev/null 2>&1; then
        rm -f "${tmp}"
        fail_file "${label}: repaired file did not validate with the corrected name"
        continue
    fi

    mv -f "${tmp}" "${file}"
    log "REPAIRED: ${label} (${embedded_name} -> ${expected_name})"
    REPAIRED=$((REPAIRED + 1))
done

echo
echo "Summary: repaired=${REPAIRED} skipped=${SKIPPED} failed=${FAILED}"

if [[ "${FAILED}" -gt 0 ]]; then
    exit 1
fi
