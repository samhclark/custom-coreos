#!/usr/bin/env bash

# Collect read-only diagnostics for the libkrun TUNSETIFF(EACCES) failure
# after the narrow nas-krun-tun SELinux module has been installed.

set -uo pipefail

export LC_ALL=C
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat

if (( EUID != 0 )); then
    echo "Run this script as root (for example: sudo bash $0)." >&2
    exit 1
fi

if (( $# > 1 )); then
    echo "usage: sudo bash $0 [JOURNAL_SINCE]" >&2
    exit 2
fi

JOURNAL_SINCE=${1:--30min}

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    local description=$1
    shift
    section "$description"
    "$@" 2>&1
    local status=$?
    if (( status != 0 )); then
        printf '[command exited with status %d]\n' "$status"
    fi
    return 0
}

section "collection metadata"
printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'selinux_mode=%s\n' "$(getenforce 2>&1)"

run "installed local SELinux modules" semodule --list-modules=full
run "narrow policy source copied to the NAS" \
    sed -n '1,80p' /var/home/core/nas-krun-tun.cil
run "container device boolean" getsebool container_use_devices

run "blackbox system and user manager state" bash -c '
    systemctl show user@51230.service \
        -p ActiveState -p SubState -p Result -p InvocationID
    runuser --user _nas_blackbox -- env \
        XDG_RUNTIME_DIR=/run/user/51230 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51230/bus \
        systemctl --user show blackbox-exporter.service \
        -p ActiveState -p SubState -p Result -p InvocationID
'
run "recent blackbox system-manager journal" journalctl \
    --since "$JOURNAL_SINCE" --no-pager -o short-precise \
    -u user@51230.service
run "recent blackbox service-user journal" journalctl \
    --since "$JOURNAL_SINCE" --no-pager -o short-precise \
    _UID=51230

run "TAP and TUN metadata" bash -c '
    ip -details tuntap show dev krun-51230
    ip -details link show dev krun-51230
    ls -lZ /dev/net/tun
    stat /dev/net/tun
'

run "interpreted SELinux AVC records involving TUN or libkrun" bash -c '
    if ! command -v ausearch >/dev/null; then
        echo "ausearch is not installed."
        exit 0
    fi
    ausearch -m AVC,USER_AVC -ts boot -i \
        | grep -Ei "tun|fc_vcpu|container_kvm|blackbox" || true
'
run "raw SELinux AVC records involving TUN or libkrun" bash -c '
    if ! command -v ausearch >/dev/null; then
        echo "ausearch is not installed."
        exit 0
    fi
    ausearch -m AVC,USER_AVC -ts boot --raw \
        | grep -Ei "tun|fc_vcpu|container_kvm|blackbox" || true
'
run "kernel audit records involving TUN or libkrun" bash -c '
    journalctl -b -k --no-pager -o short-precise \
        | grep -Ei "avc|tun|fc_vcpu|container_kvm|blackbox" || true
'

section "live libkrun VMM credentials and namespaces"
mapfile -t krun_pids < <(
    ps -e -o pid=,comm=,args= \
        | awk '$0 ~ /\[libcrun:krun\]/ { print $1 }'
)
if (( ${#krun_pids[@]} == 0 )); then
    echo "No live [libcrun:krun] process was caught; audit records remain authoritative."
else
    printf 'pids=%s\n' "${krun_pids[*]}"
    ps -o pid,ppid,user,group,label,comm,args \
        -p "$(IFS=,; echo "${krun_pids[*]}")"
    for pid in "${krun_pids[@]}"; do
        [[ -r /proc/$pid/status ]] || continue
        printf '\n--- PID %s ---\n' "$pid"
        grep -E '^(Name|Pid|PPid|Uid|Gid|Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs):' \
            "/proc/$pid/status" || true
        printf 'selinux_context='
        cat "/proc/$pid/attr/current" 2>&1 || true
        printf 'user_namespace='
        readlink "/proc/$pid/ns/user" 2>&1 || true
        printf 'network_namespace='
        readlink "/proc/$pid/ns/net" 2>&1 || true
        printf '%s\n' 'uid_map:'
        cat "/proc/$pid/uid_map" 2>&1 || true
        printf '%s\n' 'gid_map:'
        cat "/proc/$pid/gid_map" 2>&1 || true
    done
fi

section "end of diagnostics"
echo "No services, modules, interfaces, devices, booleans, or files were changed."
