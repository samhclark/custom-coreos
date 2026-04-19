#!/bin/bash
# ABOUTME: Podman shell driver store script. Encrypts secret data from stdin
# with systemd-creds and writes it to the backing store.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
podman_secret_store_context

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

install -d -m 0700 "${SECRET_STORE_DIR}"
tmp="$(mktemp "${SECRET_STORE_DIR}/${SECRET_ID}.XXXXXX.cred")"
trap 'rm -f "${tmp}"' EXIT

# systemd-creds embeds a credential name and verifies it on decrypt. Use the
# final backing-file name rather than the mktemp path so the post-write rename
# does not invalidate the credential.
if ! systemd-creds encrypt "${SECRET_CREDS_MODE[@]}" --with-key="${SECRET_CREDS_KEY}" --name "${SECRET_ID}.cred" - "${tmp}"; then
    exit 1
fi

chmod 0600 "${tmp}"
mv -f "${tmp}" "${SECRET_STORE_DIR}/${SECRET_ID}.cred"
trap - EXIT
