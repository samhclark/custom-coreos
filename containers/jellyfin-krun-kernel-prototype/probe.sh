#!/bin/bash
# ABOUTME: Requires a Linux 6.18+ guest and useful VirtIO VA-API media codec
# entrypoints; VideoProc by itself is deliberately insufficient.

set -euo pipefail

echo "== external guest kernel =="
uname -a

kernel_major="$(uname -r | cut -d. -f1)"
kernel_minor="$(uname -r | cut -d. -f2)"
if ((kernel_major < 6 || (kernel_major == 6 && kernel_minor < 18))); then
    echo "Expected an external Linux 6.18-or-newer guest kernel" >&2
    exit 41
fi

echo
echo "== guest VirtIO-GPU device =="
ls -l /dev/dri
readlink -f /sys/class/drm/renderD128/device/driver || true

echo
echo "== guest Mesa versions =="
rpm -q libva libva-utils mesa-dri-drivers
rpm -q --whatprovides /usr/lib64/dri/virtio_gpu_drv_video.so

echo
echo "== DRM native-context VA-API capabilities =="
capabilities="$({
    LIBVA_DRIVER_NAME=virtio_gpu \
    LIBVA_DRIVERS_PATH=/usr/lib64/dri \
        vainfo --display drm --device /dev/dri/renderD128
} 2>&1)"
printf '%s\n' "${capabilities}"

if ! grep -Eq 'VAEntrypoint(VLD|EncSlice|EncSliceLP)' <<<"${capabilities}"; then
    echo "No VA-API decode or encode entrypoints were exposed" >&2
    exit 42
fi

echo
echo "RESULT: external-kernel native context exposed media codec capabilities"
