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

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/caddy 0755 root root -" \
      "d /var/lib/caddy/secrets 0700 root root -" \
      "d /var/lib/caddy-config 0755 root root -" \
      > /usr/lib/tmpfiles.d/caddy.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/garage 0755 root root -" \
      "d /var/lib/garage/meta 0755 root root -" \
      "d /var/lib/garage/data 0755 root root -" \
      > /usr/lib/tmpfiles.d/garage.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    semodule -i /usr/share/selinux/targeted/gssproxy-local.cil'

RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    /bin/bash -c 'set -euo pipefail; \
    # Validate that provided kernel version matches actual CoreOS kernel \
    [[ "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")" == "${KERNEL_VERSION}" ]]; \
    arch="$(rpm -qa kernel --queryformat "%{ARCH}")"; \
    dnf install -y \
        cockpit-bridge \
        cockpit-kdump \
        cockpit-machines \
        cockpit-networkmanager \
        cockpit-ostree \
        cockpit-podman \
        cockpit-selinux \
        cockpit-storaged \
        cockpit-system \
        nftables \
        tailscale \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm \
        /zfs-rpms/*."${arch}".rpm; \
    depmod -a "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")"; \
    echo "zfs" > /etc/modules-load.d/zfs.conf; \
    rm -rf /var/lib/pcp /var/cache/dnf; \
    systemctl enable \
        bootc-fetch-apply-updates.timer \
        nftables.service \
        tailscaled.service \
        zfs-create-garage-datasets.service \
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
