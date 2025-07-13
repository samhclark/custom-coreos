# fill in ZFS version from GitHub runner
# gh release view --repo openzfs/zfs --json tagName -q '.tagName'
ARG ZFS_VERSION
ARG FEDORA_VERSION=42

# Maybe there's something to be done parsing the release notes to find the
# max compatible kernel version
# gh release view --repo openzfs/zfs | grep -E 'Linux.*compatible.*kernels' | sed 's/.*\([0-9]\+\.[0-9]\+\) kernels.*/\1/'
ARG KERNEL_MAJOR_MINOR=6.14

FROM quay.io/fedora/fedora-coreos:stable as kernel-query
ARG ZFS_VERSION
ARG FEDORA_VERSION
ARG KERNEL_MAJOR_MINOR

# Confirm the base Fedora version and the kernel version don't move too much. 
# I want to manually make changes when the kernel changes because ZFS doesn't always keep up
# Don't use `uname -r`. It will pick up the host kernel version
RUN echo "Looking for Fedora ${FEDORA_VERSION}"
RUN [[ "$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2)" == "${FEDORA_VERSION}" ]]
RUN rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' > /kernel-version.txt
RUN echo "Kernel version is $(cat /kernel-version.txt)" 
RUN [[ "$(cat /kernel-version.txt)" == ${KERNEL_MAJOR_MINOR}.* ]]

# Using https://openzfs.github.io/openzfs-docs/Developer%20Resources/Custom%20Packages.html
FROM quay.io/fedora/fedora:${FEDORA_VERSION} as builder
ARG ZFS_VERSION
ARG FEDORA_VERSION
COPY --from=kernel-query /kernel-version.txt /kernel-version.txt

# Need to add the updates archive to install specific kernel versions
WORKDIR /etc/yum.repos.d
RUN curl -L --remote-name https://src.fedoraproject.org/rpms/fedora-repos/raw/f${FEDORA_VERSION}/f/fedora-updates-archive.repo && \
    sed -i 's/enabled=AUTO_VALUE/enabled=true/' fedora-updates-archive.repo
WORKDIR /

RUN KERNEL_VERSION=$(cat /kernel-version.txt) && \
    dnf install -y autoconf automake dkms gcc \
    kernel-$KERNEL_VERSION kernel-devel-$KERNEL_VERSION kernel-modules-$KERNEL_VERSION kernel-rpm-macros \
    libaio-devel libattr-devel libblkid-devel libffi-devel libtirpc-devel libtool libunwind-devel libuuid-devel \
    make ncompress openssl openssl-devel \
    python3 python3-devel python3-cffi python3-packaging python3-setuptools \
    rpm-build systemd-devel zlib-ng-compat-devel

# It's a little weird.
# ZFS_VERSION is the tag name, which looks like: zfs-2.3.3
# But when you extract the tarball, you get a dir like zfs-zfs-2.3.3. 
# So zfs-$ZFS_VERSION is right. 
RUN KERNEL_VERSION=$(cat /kernel-version.txt) && \
    curl -L --remote-name "https://github.com/openzfs/zfs/archive/refs/tags/${ZFS_VERSION}.tar.gz" && \
    tar xzf "${ZFS_VERSION}.tar.gz" && \
    mv "zfs-${ZFS_VERSION}" zfs && \
    cd zfs && \
    ./autogen.sh && \
    ./configure -with-linux=/usr/src/kernels/$KERNEL_VERSION/ -with-linux-obj=/usr/src/kernels/$KERNEL_VERSION/ && \
    make -j1 rpm-utils rpm-kmod && \
    rm /zfs/*devel*.rpm /zfs/zfs-test*.rpm

FROM quay.io/fedora/fedora-coreos:stable
COPY --from=builder /zfs/*.rpm /zfs/
RUN rpm-ostree install \
      /zfs/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm && \
    # Auto-load ZFS module
    depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    echo "zfs" > /etc/modules-load.d/zfs.conf && \
    # we don't want any files on /var
    rm -rf /var/lib/pcp && \
    ostree container commit 
