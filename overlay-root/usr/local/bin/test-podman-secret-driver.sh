#!/bin/bash
# ABOUTME: End-to-end smoke test for the Podman shell secret driver backed by
# systemd-creds.

set -euo pipefail

TEST_IMAGE="${TEST_IMAGE:-registry.fedoraproject.org/fedora-minimal:43}"
LOOKUP_PATH="/run/secrets"

usage() {
    cat <<'USAGE'
Usage: sudo test-podman-secret-driver.sh

Environment:
  TEST_IMAGE   Container image used for the mount test.
               Default: registry.fedoraproject.org/fedora-minimal:43

This smoke test verifies:
  1. podman secret create stores an encrypted .cred backing file
  2. nas-secrets show decrypts the value correctly
  3. podman run --secret mounts the secret into a container
  4. podman secret rm removes the backing file
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 0 ]]; then
    usage >&2
    exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this test as root so it exercises the rootful Podman secret store." >&2
    exit 1
fi

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

cleanup() {
    if [[ -n "${SECRET_NAME:-}" ]] && podman secret inspect "${SECRET_NAME}" >/dev/null 2>&1; then
        podman secret rm "${SECRET_NAME}" >/dev/null 2>&1 || true
    fi
}

require_cmd podman
require_cmd nas-secrets
require_cmd systemd-creds
require_cmd grep

SECRET_NAME="podman-secret-driver-smoke-$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid)"
SECRET_VALUE="podman-secret-driver-smoke-$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid)"
SECRET_ID=""
SECRET_FILE=""

trap cleanup EXIT

echo "Testing Podman shell secret driver with systemd-creds backing store"
echo "  Image: ${TEST_IMAGE}"
echo

printf '%s' "${SECRET_VALUE}" | podman secret create "${SECRET_NAME}" - >/dev/null \
    || fail "podman secret create failed"
pass "created secret ${SECRET_NAME}"

SECRET_ID="$(podman secret inspect "${SECRET_NAME}" --format '{{.ID}}' 2>/dev/null)" \
    || fail "failed to resolve podman secret ID"
SECRET_FILE="/var/lib/podman-secrets/${SECRET_ID}.cred"

[[ -f "${SECRET_FILE}" ]] || fail "backing file not found at ${SECRET_FILE}"
pass "created encrypted backing file ${SECRET_FILE}"

if LC_ALL=C grep -Fq "${SECRET_VALUE}" "${SECRET_FILE}"; then
    fail "backing file contains plaintext secret data"
fi
pass "backing file does not contain plaintext secret data"

SHOW_VALUE="$(nas-secrets show "${SECRET_NAME}")" || fail "nas-secrets show failed"
[[ "${SHOW_VALUE}" == "${SECRET_VALUE}" ]] || fail "nas-secrets show returned the wrong value"
pass "nas-secrets show returned the expected plaintext"

if ! podman image exists "${TEST_IMAGE}"; then
    echo "Pulling ${TEST_IMAGE} for container mount test"
    podman pull "${TEST_IMAGE}" >/dev/null || fail "failed to pull ${TEST_IMAGE}"
fi

MOUNTED_VALUE="$(
    podman run --rm --pull=never --secret "${SECRET_NAME}" "${TEST_IMAGE}" \
        /bin/sh -ceu "cat '${LOOKUP_PATH}/${SECRET_NAME}'"
)" || fail "podman run --secret failed"

[[ "${MOUNTED_VALUE}" == "${SECRET_VALUE}" ]] || fail "container saw the wrong secret value"
pass "container received the expected secret contents"

podman secret rm "${SECRET_NAME}" >/dev/null || fail "podman secret rm failed"
pass "removed Podman secret"

if [[ -e "${SECRET_FILE}" ]]; then
    fail "backing file still exists after podman secret rm"
fi
pass "backing file was removed"

trap - EXIT

echo
echo "Smoke test passed"
