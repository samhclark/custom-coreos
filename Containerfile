# Build arguments - all required, no defaults
ARG KERNEL_VERSION
ARG ZFS_VERSION

#####
# 
#  Stage 1: Pull prebuilt ZFS kmods
#
#####
FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms
ARG KERNEL_VERSION
ARG ZFS_VERSION


#####
# 
#  Stage 2: Final image
#
#####
FROM quay.io/fedora/fedora-coreos:stable
ARG KERNEL_VERSION
ARG ZFS_VERSION

# Add container labels for future deduplication
LABEL org.opencontainers.image.title="Custom CoreOS with ZFS and Tailscale"
LABEL org.opencontainers.image.description="CoreOS with prebuilt ZFS kernel modules and Tailscale"
LABEL custom-coreos.zfs-version="${ZFS_VERSION}"
LABEL custom-coreos.kernel-version="${KERNEL_VERSION}"

COPY overlay-root/ /

RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    /bin/bash -c 'set -euo pipefail; \
    # Validate that provided kernel version matches actual CoreOS kernel \
    [[ "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")" == "${KERNEL_VERSION}" ]]; \
    arch="$(rpm -qa kernel --queryformat "%{ARCH}")"; \
    dnf install -y \
        cockpit-ostree \
        cockpit-podman \
        cockpit-system \
        firewalld \
        tailscale \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm \
        /zfs-rpms/*."${arch}".rpm; \
    depmod -a "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")"; \
    echo "zfs" > /etc/modules-load.d/zfs.conf; \
    rm -rf /var/lib/pcp /var/cache/dnf; \
    systemctl unmask firewalld; \
    mkdir -p /etc/systemd/system/{multi-user.target.wants,default.target.wants}; \
    ln -sf /etc/containers/systemd/cockpit-ws.container /etc/systemd/system/multi-user.target.wants/cockpit-ws.container; \
    ln -sf /etc/containers/systemd/cockpit-ws.container /etc/systemd/system/default.target.wants/cockpit-ws.container; \
    systemctl enable \
        bootc-fetch-apply-updates.service \
        firewalld.service \
        tailscaled.service \
        zfs-health-check.timer \
        zfs-scrub-monthly@tank.timer \
        zfs-snapshots-frequently@videos.timer \
        zfs-snapshots-hourly@videos.timer \
        zfs-snapshots-daily@videos.timer \
        zfs-snapshots-weekly@videos.timer \
        zfs-snapshots-monthly@videos.timer \
        zfs-snapshots-yearly@videos.timer; \
    systemctl disable zincati.service; \
    dnf clean all; \
    rm -rf /var/log/dnf*'

RUN ["bootc", "container", "lint"]

LABEL containers.bootc=1
LABEL ostree.bootable=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
