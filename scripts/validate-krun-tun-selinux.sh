#!/usr/bin/env bash

# Validate the image's narrow libkrun TUN SELinux policy with only the
# blackbox-exporter microVM. This intentionally changes live NAS state; use
# the rollback action to remove the test policy again.

set -euo pipefail

export LC_ALL=C
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat

POLICY_NAME=nas-krun-tun
SERVICE_USER=_nas_blackbox
SERVICE_UID=51230
SERVICE_UNIT=blackbox-exporter.service
SYSTEM_USER_UNIT=user@51230.service
READY_FILE=/run/nas-krun-network/policy-ready
USER_UNITS=(
    user@51110.service user@51120.service user@51210.service
    user@51220.service user@51230.service user@51240.service
    user@51250.service user@51260.service user@51310.service
)

usage() {
    cat >&2 <<EOF
usage:
  sudo bash $0 apply PATH_TO_NAS_KRUN_TUN_CIL
  sudo bash $0 status
  sudo bash $0 rollback

apply stops all nine service user managers, installs the supplied narrow
SELinux module, and starts only blackbox-exporter for validation.

rollback stops blackbox-exporter and removes the test SELinux module. It does
not restart the other service user managers.
EOF
    exit 2
}

if (( EUID != 0 )); then
    echo "Run this script as root." >&2
    exit 1
fi

cd /

user_command() {
    runuser --user "$SERVICE_USER" -- \
        env XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SERVICE_UID}/bus" \
        "$@"
}

user_systemctl() {
    user_command systemctl --user "$@"
}

module_installed() {
    semodule --list-modules=standard \
        | awk '{ print $1 }' \
        | grep -Fxq "$POLICY_NAME"
}

show_status() {
    echo "SELinux mode: $(getenforce)"
    if module_installed; then
        echo "SELinux module: ${POLICY_NAME} is installed"
    else
        echo "SELinux module: ${POLICY_NAME} is not installed"
    fi
    systemctl show "$SYSTEM_USER_UNIT" \
        --property=ActiveState --property=SubState --property=Result
    if systemctl is-active --quiet "$SYSTEM_USER_UNIT"; then
        user_systemctl show "$SERVICE_UNIT" \
            --property=ActiveState --property=SubState --property=Result
    fi
    ip -details tuntap show dev krun-51230 2>&1 || true
    curl --fail --silent --show-error --max-time 3 \
        http://127.0.0.1:9115/metrics >/dev/null \
        && echo "Blackbox metrics endpoint: reachable" \
        || echo "Blackbox metrics endpoint: not reachable"
}

validate_policy_file() {
    local policy_file=$1
    local expected_policy
    [[ -f "$policy_file" ]] || {
        echo "Policy file not found: $policy_file" >&2
        return 1
    }

    expected_policy=$(printf '%s\n' \
        '(block nas_krun_tun' \
        '  (allow container_kvm_t tun_tap_device_t (chr_file (open)))' \
        '  (allow container_kvm_t systemd_networkd_t (tun_socket (relabelfrom)))' \
        ')')
    if [[ $(<"$policy_file") != "$expected_policy" ]]; then
        echo "Refusing policy file with broad container device access or unexpected content." >&2
        return 1
    fi
}

apply_policy() {
    local policy_file=$1
    local start_epoch state

    validate_policy_file "$policy_file"
    [[ $(getenforce) == Enforcing ]] || {
        echo "SELinux must be enforcing for this validation." >&2
        return 1
    }
    [[ -r "$READY_FILE" ]] || {
        echo "Current-boot krun network readiness marker is absent." >&2
        return 1
    }
    cmp -s "$READY_FILE" /proc/sys/kernel/random/boot_id || {
        echo "The krun network readiness marker is stale." >&2
        return 1
    }

    echo "Stopping all TAP service user managers to end the failed restart loops..."
    systemctl stop "${USER_UNITS[@]}"

    echo "Installing narrow SELinux module from $policy_file..."
    semodule --install "$policy_file"
    module_installed || {
        echo "SELinux module installation did not persist." >&2
        return 1
    }

    start_epoch=$(date +%s)
    echo "Starting only ${SERVICE_UNIT} through ${SYSTEM_USER_UNIT}..."
    systemctl start "$SYSTEM_USER_UNIT"

    state=unknown
    for _ in {1..90}; do
        state=$(user_systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)
        [[ $state == active ]] && break
        [[ $state == failed ]] && break
        sleep 1
    done

    user_systemctl status --no-pager --full "$SERVICE_UNIT" || true
    user_command journalctl --user --no-pager -u "$SERVICE_UNIT" \
        --since "@${start_epoch}" \
        || true

    if journalctl -b -k --since "@${start_epoch}" --no-pager \
        | grep -E 'avc:.*denied.*(path="?/dev/net/tun|tclass=tun_socket)'; then
        echo "A new SELinux denial for the TUN device or socket occurred." >&2
        return 1
    fi

    if [[ $state != active ]]; then
        echo "${SERVICE_UNIT} did not become active (state=${state})." >&2
        return 1
    fi
    curl --fail --silent --show-error --max-time 5 \
        http://127.0.0.1:9115/metrics >/dev/null

    echo "PASS: blackbox-exporter opened its TAP and its metrics endpoint is reachable."
    echo "The other eight service user managers remain stopped."
}

rollback_policy() {
    echo "Stopping the representative service user manager..."
    systemctl stop "$SYSTEM_USER_UNIT"
    if module_installed; then
        echo "Removing SELinux module ${POLICY_NAME}..."
        semodule --remove "$POLICY_NAME"
    else
        echo "SELinux module ${POLICY_NAME} was not installed."
    fi
    echo "Rollback complete. The other service user managers remain stopped."
}

action=${1:-}
case "$action" in
    apply)
        [[ $# == 2 ]] || usage
        apply_policy "$2"
        ;;
    status)
        [[ $# == 1 ]] || usage
        show_status
        ;;
    rollback)
        [[ $# == 1 ]] || usage
        rollback_policy
        ;;
    *)
        usage
        ;;
esac
