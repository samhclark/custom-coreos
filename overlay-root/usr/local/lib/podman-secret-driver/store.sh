#!/bin/bash
# ABOUTME: Podman shell driver store script. Encrypts secret data from stdin
# with systemd-creds and writes it to the backing store.

set -euo pipefail

STORE_DIR="/var/lib/podman-secrets"

if [[ -z "${SECRET_ID:-}" ]]; then
    echo "ERROR: SECRET_ID not set" >&2
    exit 1
fi

install -d -m 0700 "${STORE_DIR}"
tmp="$(mktemp "${STORE_DIR}/${SECRET_ID}.XXXXXX.cred")"
trap 'rm -f "${tmp}"' EXIT

if ! systemd-creds encrypt --with-key=tpm2+host - "${tmp}"; then
    exit 1
fi

chmod 0600 "${tmp}"
mv -f "${tmp}" "${STORE_DIR}/${SECRET_ID}.cred"
trap - EXIT
