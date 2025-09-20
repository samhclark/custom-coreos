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
RUN chmod 600 /etc/wireguard/wg0.conf.template

RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    # Validate that provided kernel version matches actual CoreOS kernel
    [[ "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" == "${KERNEL_VERSION}" ]] && \
    rpm-ostree override remove nfs-utils-coreos \
        --install=cockpit-ostree \
        --install=cockpit-podman \
        --install=cockpit-system \
        --install=firewalld \
        --install=libnfsidmap \
        --install=sssd-nfs-idmap \
        --install=nfs-utils \
        --install=rbw \
        --install=tailscale && \
    rpm-ostree install \
        /zfs-rpms/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm && \
    # Auto-load ZFS module
    depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    echo "zfs" > /etc/modules-load.d/zfs.conf && \
    # Clean up unwanted files
    rm -rf /var/lib/pcp && \
    # Enable services
    systemctl unmask firewalld && \
    systemctl enable firewalld.service && \
    systemctl enable tailscaled.service && \
    # Commit the changes
    ostree container commit
