ARG FEDORA_VERSION=42

# Maybe there's something to be done parsing the release notes to find the
# max compatible kernel version
# gh release view --repo openzfs/zfs | grep -E 'Linux.*compatible.*kernels' | sed 's/.*\([0-9]\+\.[0-9]\+\) kernels.*/\1/'
ARG KERNEL_MAJOR_MINOR=6.14

# fill in ZFS version from GitHub runner
# gh release view --repo openzfs/zfs --json tagName -q '.tagName'
ARG ZFS_VERSION

#####
# 
#  Stage 1: Gather info about the CoreOS kernel
#
#####
FROM quay.io/fedora/fedora-coreos:stable as kernel-query
ARG FEDORA_VERSION
ARG KERNEL_MAJOR_MINOR
ARG ZFS_VERSION

# Confirm the actual kernel matches expectations
RUN rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' > /kernel-version.txt
RUN [[ "$(cat /kernel-version.txt)" == ${KERNEL_MAJOR_MINOR}.* ]]

# Confirm the actual Fedora version matches expectations
RUN [[ "$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2)" == "${FEDORA_VERSION}" ]]


#####
# 
#  Stage 2: Build ZFS kmod from source
#
#####
# as builder
FROM quay.io/fedora/fedora:${FEDORA_VERSION}
ARG ZFS_VERSION
ARG FEDORA_VERSION
COPY --from=kernel-query /kernel-version.txt /kernel-version.txt

# Need to add the updates archive to install specific kernel versions
RUN dnf install -y fedora-repos-archive

# Install ZFS build dependencies
# Using https://openzfs.github.io/openzfs-docs/Developer%20Resources/Custom%20Packages.html
RUN KERNEL_VERSION=$(cat /kernel-version.txt) && \
    dnf install -y --setopt=install_weak_deps=False \
        autoconf automake gcc \
        kernel-$KERNEL_VERSION kernel-devel-$KERNEL_VERSION kernel-modules-$KERNEL_VERSION kernel-rpm-macros \
        libaio-devel libattr-devel libblkid-devel libffi-devel libtirpc-devel libtool libunwind-devel libuuid-devel \
        make ncompress openssl openssl-devel \
        python3 python3-devel python3-cffi python3-packaging python3-setuptools \
        rpm-build systemd-devel zlib-ng-compat-devel

# Build ZFS
WORKDIR /zfs
RUN export KERNEL_VERSION=$(cat /kernel-version.txt) && \
    curl -L "https://github.com/openzfs/zfs/archive/refs/tags/${ZFS_VERSION}.tar.gz" | \
        tar xzf - -C . --strip-components 1

RUN export KERNEL_VERSION=$(cat /kernel-version.txt) && \
    ./autogen.sh && \
    ./configure \
        -with-linux=/usr/src/kernels/$KERNEL_VERSION/ \
        -with-linux-obj=/usr/src/kernels/$KERNEL_VERSION/ && \
    make -j $(nproc) rpm-utils rpm-kmod

# Remove unnecessary artifacts
RUN rm /zfs/*devel*.rpm /zfs/zfs-test*.rpm


#####
# 
#  Stage 3: Final image
#
#####
# FROM quay.io/fedora/fedora-coreos:stable

# COPY overlay-root/ /

# RUN --mount=type=bind,from=builder,source=/zfs,target=/zfs \
#     rpm-ostree install -y \
#         tailscale \
#         /zfs/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm \
#         /zfs/*.noarch.rpm && \
#     # Auto-load ZFS module
#     depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
#     echo "zfs" > /etc/modules-load.d/zfs.conf && \
#     # we don't want any files on /var
#     rm -rf /var/lib/pcp && \
#     systemctl enable tailscaled && \
#     ostree container commit 
