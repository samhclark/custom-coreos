#!/usr/bin/env bash

# Collect read-only diagnostics for libkrun OpenNetTun(EACCES) failures.

set -uo pipefail

export LC_ALL=C
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat

if (( EUID != 0 )); then
    echo "Run this script as root (for example: sudo bash $0)." >&2
    exit 1
fi

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
printf 'hostname=%s\n' "$(hostname)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'selinux_mode=%s\n' "$(getenforce 2>&1)"

run "host TUN device metadata" bash -c '
    ls -ldZ /dev /dev/net
    ls -lZ /dev/net/tun
    stat /dev/net/tun
    getfacl --absolute-names /dev/net/tun
    namei -l /dev/net/tun
    readlink -f /sys/class/misc/tun/device/driver 2>/dev/null || true
    cat /sys/class/misc/tun/dev 2>/dev/null || true
'
run "TUN kernel module" bash -c '
    lsmod | grep -E "^(tun|tap)[[:space:]]" || true
    modinfo tun
'
run "persistent TAP ownership" ip tuntap show

run "SELinux container device boolean" bash -c '
    getsebool container_use_devices
    semanage boolean -l | grep -E "^container_use_devices([[:space:]]|$)" || true
'
run "SELinux labels relevant to TUN" bash -c '
    matchpathcon -V /dev/net/tun
    ps -eZ | grep -E "(libcrun|conmon|krun|container_t)" || true
'
run "SELinux allow rules for container_t and TUN" bash -c '
    if command -v sesearch >/dev/null; then
        sesearch --allow -s container_t -t tun_tap_device_t -c chr_file
        sesearch --allow -s container_t -t device_t -c chr_file
        sesearch --allow -s container_t -c chr_file | grep -E "(tun_tap_device_t|device_t)" || true
    else
        echo "sesearch is not installed."
    fi
'

run "SELinux AVC records since boot" bash -c '
    if command -v ausearch >/dev/null; then
        ausearch -m AVC,USER_AVC -ts boot -i
    else
        echo "ausearch is not installed."
    fi
'
run "kernel and audit journal permission denials" bash -c '
    journalctl -b --no-pager -o short-monotonic -k \
        | grep -Ei "avc|denied|selinux|tun|audit" || true
    journalctl -b --no-pager -o short-monotonic _TRANSPORT=audit \
        | grep -Ei "avc|denied|selinux|tun|krun|conmon" || true
'

run "libkrun TAP failures" bash -c '
    journalctl -b --no-pager -o short-monotonic \
        | grep -E "OpenNetTun|BadActivate|virtio-net.*backend" || true
'

section "live libkrun process contexts"
mapfile -t krun_pids < <(
    ps -e -o pid=,comm=,args= \
        | awk '$0 ~ /\[libcrun:krun\]/ { print $1 }'
)
if (( ${#krun_pids[@]} == 0 )); then
    echo "No live [libcrun:krun] process was found."
else
    printf 'pids=%s\n' "${krun_pids[*]}"
    ps -o pid,ppid,user,group,label,comm,args -p "$(IFS=,; echo "${krun_pids[*]}")"

    inspected=0
    for pid in "${krun_pids[@]}"; do
        [[ -d "/proc/${pid}" ]] || continue
        section "mount namespace TUN view for PID ${pid}"
        printf 'mount_namespace='
        readlink "/proc/${pid}/ns/mnt" 2>&1 || true
        printf 'process_context='
        cat "/proc/${pid}/attr/current" 2>&1 || true
        ls -ldZ "/proc/${pid}/root/dev" "/proc/${pid}/root/dev/net" 2>&1 || true
        ls -lZ "/proc/${pid}/root/dev/net/tun" 2>&1 || true
        stat -L "/proc/${pid}/root/dev/net/tun" 2>&1 || true
        grep -E "(/dev/net/tun| /dev |/dev/)" "/proc/${pid}/mountinfo" 2>&1 || true

        (( inspected += 1 ))
        if (( inspected == 3 )); then
            echo "Limited mount-namespace inspection to three representative VMMs."
            break
        fi
    done
fi

# Variables in this single-quoted program intentionally expand in the child shell.
# shellcheck disable=SC2016
run "representative rootless Podman device configuration" bash -c '
    cd /
    user=_nas_grafana
    uid=51210
    name=grafana
    if ! runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman container exists "$name"; then
        echo "Container ${name} does not exist for ${user}."
        exit 0
    fi
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman container inspect "$name" \
        --format "Devices={{json .HostConfig.Devices}}"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman container inspect "$name" \
        --format "ProcessLabel={{.ProcessLabel}} MountLabel={{.MountLabel}}"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman container inspect "$name" \
        --format "State={{.State.Status}} Runtime={{.OCIRuntime}} Pid={{.State.Pid}}"
'

section "end of diagnostics"
echo "No services, containers, interfaces, devices, booleans, or files were changed."
