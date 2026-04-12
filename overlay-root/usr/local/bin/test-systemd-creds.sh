#!/bin/bash
# ABOUTME: Low-level validation that systemd-creds encrypt/decrypt works with
# TPM on this machine. This does not exercise the Podman shell secret driver.

set -euo pipefail

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

run_test() {
    local name="$1"
    local input="$2"
    local cred_file="${TMPDIR}/${name}.cred"

    # Encrypt
    if ! printf '%s' "$input" | systemd-creds encrypt --with-key=tpm2+host - "$cred_file" 2>/dev/null; then
        fail "${name}: encrypt failed"
        return
    fi

    # Decrypt
    local output
    if ! output="$(systemd-creds decrypt "$cred_file" - 2>/dev/null)"; then
        fail "${name}: decrypt failed"
        return
    fi

    # Compare
    if [[ "$output" != "$input" ]]; then
        fail "${name}: round-trip mismatch"
        return
    fi

    pass "$name"
}

echo "Testing systemd-creds with --with-key=tpm2+host"
echo

echo "Basic round-trip tests:"
run_test "simple-string" "hello-world-secret-value"
run_test "empty-string" ""
run_test "multiline" "line1
line2
line3"
run_test "trailing-newline" "secret-value
"
run_test "long-value" "$(head -c 4096 /dev/urandom | base64)"

echo
echo "Repeated decrypt test:"
REPEAT_INPUT="repeated-decrypt-test"
REPEAT_FILE="${TMPDIR}/repeat.cred"
if printf '%s' "$REPEAT_INPUT" | systemd-creds encrypt --with-key=tpm2+host - "$REPEAT_FILE" 2>/dev/null; then
    repeat_ok=true
    for i in 1 2 3; do
        output="$(systemd-creds decrypt "$REPEAT_FILE" - 2>/dev/null)" || { repeat_ok=false; break; }
        [[ "$output" == "$REPEAT_INPUT" ]] || { repeat_ok=false; break; }
    done
    if $repeat_ok; then
        pass "decrypt-three-times"
    else
        fail "decrypt-three-times"
    fi
else
    fail "decrypt-three-times: encrypt failed"
fi

echo
echo "Name credential test (encrypt with --name, decrypt without service context):"
NAME_INPUT="named-secret-value"
NAME_FILE="${TMPDIR}/named.cred"
if printf '%s' "$NAME_INPUT" | systemd-creds encrypt --with-key=tpm2+host --name=test-secret - "$NAME_FILE" 2>/dev/null; then
    # Try decrypting with matching --name
    if output="$(systemd-creds decrypt --name=test-secret "$NAME_FILE" - 2>/dev/null)" && [[ "$output" == "$NAME_INPUT" ]]; then
        pass "named-encrypt-matching-decrypt"
    else
        fail "named-encrypt-matching-decrypt"
    fi

    # Try decrypting without --name (should this work?)
    if output="$(systemd-creds decrypt "$NAME_FILE" - 2>/dev/null)" && [[ "$output" == "$NAME_INPUT" ]]; then
        pass "named-encrypt-unnamed-decrypt"
    else
        fail "named-encrypt-unnamed-decrypt (not necessarily a problem — just means we should not use --name)"
    fi
else
    fail "named-encrypt: encrypt with --name failed"
fi

echo
echo "---"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
