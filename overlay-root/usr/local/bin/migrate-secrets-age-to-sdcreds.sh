#!/bin/bash
# ABOUTME: One-time migration script that creates systemd-creds encrypted copies
# of all age-encrypted podman secrets. Additive only: does not delete .age files
# or modify the shell driver.

set -euo pipefail

IDENTITY_FILE="/var/lib/age-tpm/identity.txt"
STORE_DIR="/var/lib/podman-secrets"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [[ ! -f "$IDENTITY_FILE" ]]; then
    echo "ERROR: age identity not found at $IDENTITY_FILE" >&2
    echo "Is age-tpm-identity.service running?" >&2
    exit 1
fi

shopt -s nullglob
age_files=("${STORE_DIR}"/*.age)

if [[ ${#age_files[@]} -eq 0 ]]; then
    log "No .age files found in $STORE_DIR. Nothing to migrate."
    exit 0
fi

log "Found ${#age_files[@]} secret(s) to migrate"
echo

migrated=0
failed=0

for age_file in "${age_files[@]}"; do
    secret_id="$(basename "$age_file" .age)"
    cred_file="${STORE_DIR}/${secret_id}.cred"

    echo "--- ${secret_id} ---"

    if [[ -f "$cred_file" ]]; then
        log "SKIP: ${secret_id} — .cred file already exists"
        echo
        continue
    fi

    # Decrypt with age
    plaintext="$(age -d -i "$IDENTITY_FILE" "$age_file")" || {
        log "FAIL: ${secret_id} — age decrypt failed"
        failed=$((failed + 1))
        echo
        continue
    }

    # Re-encrypt with systemd-creds
    printf '%s' "$plaintext" | systemd-creds encrypt --with-key=tpm2+host - "$cred_file" || {
        log "FAIL: ${secret_id} — systemd-creds encrypt failed"
        failed=$((failed + 1))
        echo
        continue
    }

    # Verify round-trip
    verify="$(systemd-creds decrypt "$cred_file" -)" || {
        log "FAIL: ${secret_id} — systemd-creds decrypt verification failed"
        rm -f "$cred_file"
        failed=$((failed + 1))
        echo
        continue
    }

    if [[ "$verify" != "$plaintext" ]]; then
        log "FAIL: ${secret_id} — round-trip mismatch"
        rm -f "$cred_file"
        failed=$((failed + 1))
        echo
        continue
    fi

    log "OK: ${secret_id} — migrated and verified"
    migrated=$((migrated + 1))
    echo
done

echo "=== Summary ==="
echo "Migrated: ${migrated}"
echo "Failed:   ${failed}"
echo "Skipped:  $(( ${#age_files[@]} - migrated - failed ))"
echo
echo "The .age files have NOT been removed."
echo "The shell driver has NOT been changed."
echo "Both .age and .cred files now exist side by side."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
