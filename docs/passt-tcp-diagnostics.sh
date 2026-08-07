#!/usr/bin/env bash
# ABOUTME: Read-only diagnostics for Caddy TCP ingress after the private-passt
# migration. This does not restart services or change host/container state.

set -uo pipefail

section() {
    printf '\n===== %s =====\n' "$1"
}

curl_verbose() {
    local label=$1
    shift
    printf '\n--- %s ---\n' "$label"
    curl --noproxy '*' --verbose --max-time 7 "$@" 2>&1 || true
}

section "Timestamp and identity"
date --iso-8601=seconds
id

section "Hostname resolution"
getent ahostsv4 jellyfin.i.samhclark.com || true
getent ahostsv4 visualize.i.samhclark.com || true

section "Direct loopback backends"
printf 'Caddy metrics: '
curl --noproxy '*' --fail --silent --show-error --max-time 3 \
    http://127.0.0.1:2019/metrics >/dev/null && echo OK || echo FAILED
printf 'Jellyfin health: '
curl --noproxy '*' --fail --silent --show-error --max-time 3 \
    http://127.0.0.1:8096/health || true
printf '\nGrafana health: '
curl --noproxy '*' --fail --silent --show-error --max-time 3 \
    http://127.0.0.1:3000/api/health || true
printf '\n'

section "Caddy TCP through host loopback"
curl_verbose "Jellyfin HTTPS forced to 127.0.0.1" \
    --resolve jellyfin.i.samhclark.com:443:127.0.0.1 \
    https://jellyfin.i.samhclark.com/health
curl_verbose "Grafana HTTPS forced to 127.0.0.1" \
    --resolve visualize.i.samhclark.com:443:127.0.0.1 \
    https://visualize.i.samhclark.com/api/health
curl_verbose "HTTP redirect through 127.0.0.1" http://127.0.0.1/

section "Caddy TCP through normal hostname resolution"
curl_verbose "Jellyfin HTTPS normally resolved" \
    https://jellyfin.i.samhclark.com/health
curl_verbose "Grafana HTTPS normally resolved" \
    https://visualize.i.samhclark.com/api/health

section "TCP and QUIC TLS handshakes through loopback"
printf '\n--- TCP 443 ---\n'
timeout 8s openssl s_client \
    -connect 127.0.0.1:443 \
    -servername jellyfin.i.samhclark.com \
    -brief </dev/null 2>&1 || true
printf '\n--- QUIC/UDP 443 ---\n'
timeout 8s openssl s_client \
    -quic \
    -alpn h3 \
    -connect 127.0.0.1:443 \
    -servername jellyfin.i.samhclark.com </dev/null 2>&1 |
    grep -E 'Verification|Protocol|ALPN|error|errno' || true

section "Host listeners"
sudo ss -H -ltnup \
    '( sport = :80 or sport = :443 or sport = :2019 or sport = :8096 )' || true

section "Caddy Podman configuration"
(
    cd /
    sudo -u _nas_caddy env \
        HOME=/var/home/_nas_caddy \
        XDG_RUNTIME_DIR=/run/user/51310 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
        podman inspect caddy --format \
        'pid={{.State.Pid}} runtime={{.OCIRuntime}} status={{.State.Status}} network={{.HostConfig.NetworkMode}} ports={{json .NetworkSettings.Ports}} annotations={{json .Config.Annotations}}'
) || true

section "Caddy pasta and passt processes"
pgrep -a -u 51310 'pasta|passt|libcrun|VM:' || true

section "Caddy private-namespace listeners"
caddy_pid=$(
    cd /
    sudo -u _nas_caddy env \
        HOME=/var/home/_nas_caddy \
        XDG_RUNTIME_DIR=/run/user/51310 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
        podman inspect caddy --format '{{.State.Pid}}' 2>/dev/null
) || caddy_pid=
if [[ $caddy_pid =~ ^[0-9]+$ ]]; then
    printf 'VMM PID: %s\n' "$caddy_pid"
    sudo readlink "/proc/$caddy_pid/ns/net" || true
    sudo nsenter -t "$caddy_pid" -n ss -H -ltnup \
        '( sport = :80 or sport = :443 or sport = :2019 or sport = :3000 or sport = :3900 or sport = :3903 or sport = :8096 or sport = :8428 )' || true
    printf '\nVMM main-thread stack:\n'
    sudo cat "/proc/$caddy_pid/stack" || true
else
    echo "Could not determine Caddy VMM PID"
fi

section "Recent Caddy journal"
sudo journalctl _UID=51310 -b --since '-15 minutes' --no-pager -n 200 || true

section "Completed"
echo "Read-only diagnostics complete; no services were restarted or changed."
