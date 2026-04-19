#!/bin/bash
# ABOUTME: Podman shell driver store script. Encrypts secret data from stdin
# with systemd-creds and writes it to the backing store.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    STORE_DIR="/var/lib/podman-secrets"
    CREDS_MODE=()
else
    STORE_DIR="/var/lib/podman-secrets/$(id -un)"
    CREDS_MODE=(--user)
fi

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

install -d -m 0700 "${STORE_DIR}"
tmp="$(mktemp "${STORE_DIR}/${SECRET_ID}.XXXXXX.cred")"
trap 'rm -f "${tmp}"' EXIT

# systemd-creds embeds a credential name and verifies it on decrypt. Use the
# final backing-file name rather than the mktemp path so the post-write rename
# does not invalidate the credential.
if ! systemd-creds encrypt "${CREDS_MODE[@]}" --with-key=tpm2+host --name "${SECRET_ID}.cred" - "${tmp}"; then
    exit 1
fi

chmod 0600 "${tmp}"
mv -f "${tmp}" "${STORE_DIR}/${SECRET_ID}.cred"
trap - EXIT
