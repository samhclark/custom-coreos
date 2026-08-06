#!/bin/bash
# ABOUTME: Collects read-only evidence for Jellyfin health-probe failures,
# playback load, and future Intel hardware-transcoding configuration.

echo "== direct and blackbox health =="
curl -sS -o /dev/null \
    -w 'direct status=%{http_code} time=%{time_total}s\n' \
    http://127.0.0.1:8096/health
curl -fsSG http://127.0.0.1:9115/probe \
    --data-urlencode 'module=http_2xx' \
    --data-urlencode 'target=http://127.0.0.1:8096/health' |
    grep -E '^probe_(success|duration_seconds|http_status_code|failed_due_to_regex|dns_lookup_time_seconds|ip_protocol)($|[[:space:]])'

echo "== host and Jellyfin load =="
uptime
free -h
ps -eo pid,comm,%cpu,%mem,args --sort=-%cpu | head -15
runuser -u _nas_jellyfin -- env \
    HOME=/var/home/_nas_jellyfin \
    XDG_RUNTIME_DIR=/run/user/51120 \
    podman stats --no-stream jellyfin || true

echo "== recent Jellyfin playback evidence =="
journalctl _UID=51120 -b --since '-15 minutes' --no-pager |
    grep -Ei 'ffmpeg|transcod|direct.?play|slow|warn|error' |
    tail -160 || true

echo "== Intel render devices =="
lspci -nnk | grep -A4 -Ei 'vga|display|3d' || true
ls -l /dev/dri 2>&1 || true
stat -c '%t:%T %U:%G %a %n' /dev/dri/renderD* 2>&1 || true
getent group render video || true
for device in /sys/class/drm/renderD*/device/driver
do
    if [[ -e "${device}" ]]; then
        printf '%s -> %s\n' "${device}" "$(readlink -f "${device}")"
    fi
done

echo "== relevant runtime versions =="
podman --version
crun --version | head -5
rpm -q crun-krun libkrun libkrunfw 2>&1 || true
