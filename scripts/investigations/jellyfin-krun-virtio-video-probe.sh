#!/bin/bash
# ABOUTME: Tests VA-API through libkrun's mediated VirtIO-GPU DRM native
# context using a disposable Fedora guest with a current Mesa driver.

set -u

SERVICE_USER="_nas_jellyfin"
SERVICE_UID="51120"
IMAGE="quay.io/fedora/fedora:44"
# crun's documented DRM native-context mask:
# USE_EGL | THREAD_SYNC | NO_VIRGL | ASYNC_FENCE_CB | DRM
GPU_FLAGS="1411"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

rootless_podman() {
    runuser -u "${SERVICE_USER}" -- env \
        HOME="/var/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
        podman "$@"
}

echo "== host libkrun and virglrenderer prerequisites =="
rpm -q crun-krun libkrun libkrunfw virglrenderer 2>&1 || true

if [[ -x /usr/libexec/virgl_render_server ]]; then
    echo "render server present: /usr/libexec/virgl_render_server"
else
    echo "render server missing: /usr/libexec/virgl_render_server"
fi

python3 - <<'PY' 2>&1 || true
import ctypes
import ctypes.util

path = ctypes.util.find_library("krun") or "libkrun.so.1"
libkrun = ctypes.CDLL(path)
libkrun.krun_has_feature.argtypes = [ctypes.c_uint64]
libkrun.krun_has_feature.restype = ctypes.c_int
# libkrun.h: KRUN_FEATURE_GPU = 2
result = libkrun.krun_has_feature(2)
print(f"libkrun GPU feature result: {result} (1 means enabled)")
PY

stat -c '%t:%T %U:%G %a %n' /dev/dri/renderD128
if runuser -u "${SERVICE_USER}" -- test -r /dev/dri/renderD128 && \
   runuser -u "${SERVICE_USER}" -- test -w /dev/dri/renderD128
then
    echo "${SERVICE_USER} can read and write the host render node"
else
    echo "${SERVICE_USER} cannot read and write the host render node"
fi
echo

# Do not let runuser inherit the operator's private home as its working
# directory. The service account cannot traverse /var/home/core by design.
cd /

echo "== mediated krun VA-API probe =="
echo "This does not mount NAS data or stop the running Jellyfin service."
echo "It downloads Mesa tools inside a disposable Fedora container overlay."

# crun 1.28 checks both paths in the prepared OCI filesystem before it asks
# libkrun to create the mediated device. The native-context mask does not
# launch virgl_render_server, but crun still requires its path.
rootless_podman run --rm \
    --runtime=krun \
    --device=/dev/dri/renderD128:/dev/dri/renderD128 \
    --volume=/usr/libexec/virgl_render_server:/usr/libexec/virgl_render_server:ro \
    --annotation=krun.cpus=2 \
    --annotation=krun.ram_mib=2048 \
    --annotation="krun.gpu_flags=${GPU_FLAGS}" \
    --entrypoint=/bin/bash \
    "${IMAGE}" \
    -lc '
        set -u

        echo "-- installing current disposable guest Mesa tooling --"
        dnf install --assumeyes --setopt=install_weak_deps=False \
            libva-utils mesa-dri-drivers mesa-va-drivers pciutils

        echo "-- guest kernel and Mesa versions --"
        uname -a
        rpm -q libva libva-utils mesa-dri-drivers mesa-va-drivers

        echo "-- guest VirtIO-GPU device --"
        ls -l /dev/dri 2>&1 || true
        lspci -nnk 2>&1 | grep -A4 -B2 -Ei "virtio|vga|display" || true
        readlink -f /sys/class/drm/renderD128/device/driver 2>&1 || true
        grep -E "virtio_gpu|drm" /proc/modules 2>&1 || true

        echo "-- Mesa guest VA-API drivers --"
        find /usr/lib64/dri \
            -maxdepth 1 -name "*_drv_video.so" -printf "%f\n" 2>&1 | sort

        echo "-- DRM native-context VA-API capabilities --"
        capabilities="$({
            LIBVA_DRIVER_NAME=virtio_gpu \
            LIBVA_DRIVERS_PATH=/usr/lib64/dri \
                /usr/bin/vainfo \
                    --display drm \
                    --device /dev/dri/renderD128
        } 2>&1)"
        printf "%s\n" "${capabilities}"

        if ! grep -Eq "VAEntrypoint(VLD|EncSlice|EncSliceLP)" \
            <<<"${capabilities}"
        then
            echo "No VA-API decode or encode entrypoints were exposed" >&2
            exit 42
        fi
    '
status=$?

echo
if [[ "${status}" -eq 0 ]]; then
    echo "RESULT: libkrun exposed VA-API decode or encode capabilities"
elif [[ "${status}" -eq 42 ]]; then
    echo "RESULT: VirtIO VA-API initialized but exposed no decode or encode capabilities"
else
    echo "RESULT: libkrun mediated VA-API failed with status ${status}"
fi
exit "${status}"
