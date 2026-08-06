#!/bin/bash
# ABOUTME: Compares Intel VA-API render-device access in disposable Jellyfin
# containers under ordinary crun and libkrun. It mounts no NAS data.

set -u

SERVICE_USER="_nas_jellyfin"
SERVICE_UID="51120"
IMAGE="docker.io/jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db"
DEVICE="/dev/dri/renderD128"

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

probe_runtime() {
    local runtime="$1"
    local status

    echo "== ${runtime} VA-API probe =="
    rootless_podman run --rm \
        --runtime="${runtime}" \
        --device="${DEVICE}:${DEVICE}" \
        --annotation=krun.cpus=1 \
        --annotation=krun.ram_mib=1024 \
        --entrypoint=/usr/lib/jellyfin-ffmpeg/vainfo \
        "${IMAGE}" \
        --display drm \
        --device "${DEVICE}"
    status=$?

    if [[ "${status}" -eq 0 ]]; then
        echo "RESULT: ${runtime} can use ${DEVICE}"
    else
        echo "RESULT: ${runtime} probe failed with status ${status}"
    fi
    echo
}

cd /

echo "== host device =="
stat -c '%t:%T %U:%G %a %n' "${DEVICE}"
if runuser -u "${SERVICE_USER}" -- test -r "${DEVICE}" && \
   runuser -u "${SERVICE_USER}" -- test -w "${DEVICE}"
then
    echo "${SERVICE_USER} can read and write ${DEVICE}"
else
    echo "${SERVICE_USER} cannot read and write ${DEVICE}"
fi
echo

probe_runtime crun
probe_runtime krun
