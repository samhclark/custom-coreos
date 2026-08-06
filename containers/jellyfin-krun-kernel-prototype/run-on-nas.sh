#!/bin/bash
# ABOUTME: Loads and runs the disposable Linux 6.18 libkrun GPU probe on the
# NAS without mounting Jellyfin data or exposing passt on the host network.

set -u

SERVICE_USER="_nas_jellyfin"
SERVICE_UID="51120"
IMAGE="localhost/jellyfin-krun-kernel-prototype:6.18.42"
ARCHIVE="${1:-/var/tmp/jellyfin-krun-kernel-prototype-6.18.42.oci.tar}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

if [[ ! -r "${ARCHIVE}" ]]; then
    echo "OCI archive is not readable: ${ARCHIVE}" >&2
    exit 1
fi

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

echo "== host prerequisites =="
rpm -q crun-krun libkrun libkrunfw virglrenderer passt 2>&1 || true
stat -c '%t:%T %U:%G %a %n' /dev/dri/renderD128
if runuser -u "${SERVICE_USER}" -- test -r /dev/dri/renderD128 && \
   runuser -u "${SERVICE_USER}" -- test -w /dev/dri/renderD128
then
    echo "${SERVICE_USER} can read and write the host render node"
else
    echo "${SERVICE_USER} cannot read and write the host render node" >&2
    exit 1
fi

echo
echo "== load prototype into the Jellyfin user's rootless image store =="
cd /
rootless_podman load --input "${ARCHIVE}" || exit $?

echo
echo "== isolated Linux 6.18 libkrun VA-API probe =="
echo "Jellyfin remains running; no config, cache, or media path is mounted."
echo "passt runs inside a temporary host network namespace, so its broad"
echo "port forwarding cannot bind production host ports."

unshare --net --mount-proc /bin/bash -s <<EOF
set -u
/usr/sbin/ip link set lo up

exec timeout --signal=TERM --kill-after=10s 180s \
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman run --rm --pull=never \
            --runtime=krun \
            --device=/dev/dri/renderD128:/dev/dri/renderD128 \
            --annotation=krun.cpus=2 \
            --annotation=krun.ram_mib=2048 \
            --annotation=krun.gpu_flags=1411 \
            --annotation=krun.use_passt=1 \
            "${IMAGE}"
EOF
status=$?

echo
if [[ "${status}" -eq 0 ]]; then
    echo "RESULT: Linux 6.18 exposed VA-API decode or encode under libkrun"
elif [[ "${status}" -eq 42 ]]; then
    echo "RESULT: VA-API initialized but exposed no decode or encode capabilities"
elif [[ "${status}" -eq 124 || "${status}" -eq 137 ]]; then
    echo "RESULT: probe timed out with status ${status}"
else
    echo "RESULT: probe failed with status ${status}"
fi

echo "The imported image remains in ${SERVICE_USER}'s rootless store."
echo "After diagnosis, remove it with:"
echo "  sudo runuser -u ${SERVICE_USER} -- env HOME=/var/home/${SERVICE_USER} XDG_RUNTIME_DIR=/run/user/${SERVICE_UID} podman image rm ${IMAGE}"
exit "${status}"
