#!/bin/bash
# ABOUTME: Records a one-time, read-only baseline before Caddy's rootless
# ownership and service migration.

set -euo pipefail

REPORT_DIR="/var/lib/nas-migrations/caddy-rootless-preflight-v1"
SERVICE_USER="_nas_caddy"
SERVICE_UID="51310"
SERVICE_GID="51310"
SUBID_START="513100000"
SUBID_COUNT="65536"
RUNTIME_SECRET="/run/nas-secrets/caddy/cf-api-token"
ROOTFUL_QUADLET="/etc/containers/systemd/caddy.container"
TEST_PORT="81"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

capture() {
    local name="$1"
    shift

    log "Recording ${name}"
    "$@" 2>&1 | tee "${REPORT_DIR}/${name}.txt"
}

record_success() {
    local name="$1"
    local message="$2"

    log "Recording ${name}"
    printf '%s\n' "${message}" | tee "${REPORT_DIR}/${name}.txt"
}

assert_metadata() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(stat -c '%u:%g %a' "${path}")"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "Unexpected metadata for ${path}: got ${actual}, expected ${expected}"
    fi
}

scan_tree() {
    local name="$1"
    local path="$2"
    local report="${REPORT_DIR}/${name}-scan.txt"

    log "Scanning metadata under ${path}"
    {
        printf 'path=%s\n' "${path}"
        find "${path}" -xdev -printf '%U:%G\n' | sort | uniq -c | sed 's/^/owners /'
        find "${path}" -xdev -printf '%m\n' | sort | uniq -c | sed 's/^/modes /'
        find "${path}" -xdev -printf '%Z\n' | sort | uniq -c | sed 's/^/labels /'
        find "${path}" -xdev -type f -printf . | wc -c | awk '{print "files " $1}'
        du -sx --bytes "${path}" | awk '{print "bytes " $1}'
    } | tee "${report}"
}

validate_tree() {
    local path="$1"
    local unexpected_owner

    unexpected_owner="$(
        find "${path}" -xdev \( ! -uid 0 -o ! -gid 0 \) -print -quit
    )"
    if [[ -n "${unexpected_owner}" ]]; then
        fail "Unexpected non-root ownership under ${path}: ${unexpected_owner}"
    fi

    if ! find "${path}" -xdev -printf '%Z\n' |
        awk -F: '$3 != "container_file_t" { exit 1 }'; then
        fail "Unexpected SELinux type under ${path}; expected container_file_t"
    fi
}

record_listeners() {
    echo "TCP 80/443"
    ss -ltnp | awk '$4 ~ /:(80|443)$/ { print }'
    echo "UDP 443"
    ss -lunp | awk '$4 ~ /:443$/ { print }'
}

record_mounts() {
    findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS -T /var/lib/caddy
    findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS -T /var/lib/caddy-config
}

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

test_low_port_bind() {
    local protocol="$1"
    local -a args=(--listen="127.0.0.1:${TEST_PORT}" --now)

    if [[ "${protocol}" == "udp" ]]; then
        args+=(--datagram)
    fi

    log "Testing ${protocol^^} low-port bind as ${SERVICE_USER} on loopback:${TEST_PORT}"
    runuser -u "${SERVICE_USER}" -- \
        systemd-socket-activate "${args[@]}" /usr/bin/true \
        > "${REPORT_DIR}/low-port-${protocol}.txt" 2>&1 ||
        fail "${SERVICE_USER} could not bind ${protocol^^} port ${TEST_PORT}"
}

install -d -m 0700 -o root -g root "${REPORT_DIR}"

[[ -e "${ROOTFUL_QUADLET}" ]] ||
    fail "Rootful Caddy Quadlet is missing during the preflight release"
[[ ! -e "/etc/containers/systemd/users/${SERVICE_UID}/caddy.container" ]] ||
    fail "A rootless Caddy Quadlet exists during the preflight release"
systemctl is-active --quiet caddy.service || fail "Rootful caddy.service is not active"
podman container exists caddy || fail "Rootful Caddy container is missing"

unprivileged_start="$(sysctl -n net.ipv4.ip_unprivileged_port_start)"
[[ "${unprivileged_start}" == "80" ]] ||
    fail "net.ipv4.ip_unprivileged_port_start is ${unprivileged_start}, expected 80"
read -r ephemeral_start _ephemeral_end < <(sysctl -n net.ipv4.ip_local_port_range)
if (( unprivileged_start > ephemeral_start )); then
    fail "Unprivileged port threshold overlaps the ephemeral port range"
fi

passwd_uid="$(getent passwd "${SERVICE_USER}" | cut -d: -f3)"
passwd_gid="$(getent passwd "${SERVICE_USER}" | cut -d: -f4)"
group_gid="$(getent group "${SERVICE_USER}" | cut -d: -f3)"
[[ "${passwd_uid}:${passwd_gid}:${group_gid}" == "${SERVICE_UID}:${SERVICE_GID}:${SERVICE_GID}" ]] ||
    fail "Unexpected ${SERVICE_USER} UID/GID allocation"
grep -Fxq "${SERVICE_USER}:${SUBID_START}:${SUBID_COUNT}" /etc/subuid ||
    fail "Missing expected /etc/subuid entry for ${SERVICE_USER}"
grep -Fxq "${SERVICE_USER}:${SUBID_START}:${SUBID_COUNT}" /etc/subgid ||
    fail "Missing expected /etc/subgid entry for ${SERVICE_USER}"
systemctl is-active --quiet "user@${SERVICE_UID}.service" ||
    fail "user@${SERVICE_UID}.service is not active"
if rootless_podman container exists caddy; then
    fail "A Caddy container already exists in ${SERVICE_USER}'s Podman store"
fi

[[ -r "${RUNTIME_SECRET}" ]] || fail "Caddy runtime secret is missing"
assert_metadata "/run/nas-secrets/caddy" "0:${SERVICE_GID} 710"
assert_metadata "${RUNTIME_SECRET}" "${SERVICE_UID}:${SERVICE_GID} 400"
runuser -u "${SERVICE_USER}" -- test -r "${RUNTIME_SECRET}" ||
    fail "${SERVICE_USER} cannot read its runtime secret"
podman secret inspect cf-api-token >/dev/null 2>&1 ||
    fail "Rootful cf-api-token Podman secret is missing"
if ! cmp -s <(/usr/local/bin/nas-secrets show cf-api-token) "${RUNTIME_SECRET}"; then
    fail "Rootful and runtime copies of cf-api-token differ"
fi

if ss -H -ltn "sport = :${TEST_PORT}" | grep -q . ||
   ss -H -lun "sport = :${TEST_PORT}" | grep -q .; then
    fail "Low-port test port ${TEST_PORT} is already occupied"
fi
test_low_port_bind tcp
test_low_port_bind udp

capture timestamp date --iso-8601=seconds
capture boot-id cat /proc/sys/kernel/random/boot_id
capture sysctl sysctl \
    net.ipv4.ip_unprivileged_port_start net.ipv4.ip_local_port_range
capture identity bash -c "
    getent passwd '${SERVICE_USER}'
    getent group '${SERVICE_USER}'
    grep -F '${SERVICE_USER}:' /etc/subuid /etc/subgid
    loginctl show-user '${SERVICE_USER}' -p Linger -p State
    systemctl is-active 'user@${SERVICE_UID}.service'
"
capture rootless-podman rootless_podman info --format \
    'rootless={{.Host.Security.Rootless}} graph_root={{.Store.GraphRoot}} run_root={{.Store.RunRoot}}'
grep -q '^rootless=true ' "${REPORT_DIR}/rootless-podman.txt" ||
    fail "Podman did not report a rootless store for ${SERVICE_USER}"
capture rootful-unit systemctl show caddy.service \
    -p ActiveState -p SubState -p FragmentPath
capture image podman inspect caddy --format \
    'image={{.ImageName}} image_id={{.Image}} user={{json .Config.User}} network={{.HostConfig.NetworkMode}}'
capture version podman exec caddy caddy version
if ! podman exec caddy caddy validate \
    --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    fail "The active Caddy configuration did not validate"
fi
record_success config "active_config=valid"
capture listeners record_listeners

ss -H -ltn | awk '$4 ~ /:80$/ { found=1 } END { exit !found }' ||
    fail "No TCP listener found on port 80"
ss -H -ltn | awk '$4 ~ /:443$/ { found=1 } END { exit !found }' ||
    fail "No TCP listener found on port 443"
ss -H -lun | awk '$4 ~ /:443$/ { found=1 } END { exit !found }' ||
    fail "No UDP listener found on port 443 for HTTP/3"

capture mounts record_mounts
capture roots stat -c '%u:%g %a %C %n' \
    /var/lib/caddy /var/lib/caddy-config
scan_tree caddy-data /var/lib/caddy
scan_tree caddy-config /var/lib/caddy-config
validate_tree /var/lib/caddy
validate_tree /var/lib/caddy-config
capture state-inventory bash -c '
    find /var/lib/caddy /var/lib/caddy-config -xdev -type f \
        -printf "%p\t%s bytes\n" | sort
'
capture secret-routing bash -c "
    stat -c '%U:%G %a %n' /run/nas-secrets/caddy '${RUNTIME_SECRET}'
    echo 'rootful_podman_secret=present'
    echo 'runtime_secret=readable-by-${SERVICE_USER}'
    echo 'secret_copies=identical'
"
if ! curl -fsS http://127.0.0.1:2019/metrics >/dev/null; then
    fail "Caddy metrics endpoint is unavailable"
fi
record_success metrics "http://127.0.0.1:2019/metrics=reachable"
capture http-redirect curl -fsS -D - -o /dev/null \
    --resolve visualize.i.samhclark.com:80:127.0.0.1 \
    http://visualize.i.samhclark.com/
capture https-garage-health curl -fsS \
    --resolve garage.i.samhclark.com:443:127.0.0.1 \
    https://garage.i.samhclark.com/health

touch "${REPORT_DIR}/complete"
log "Caddy rootless preflight completed: ${REPORT_DIR}"
