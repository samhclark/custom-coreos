# Build arguments - all required, no defaults
ARG KERNEL_VERSION
ARG ZFS_VERSION

#####
#
#  Stage 1: Build crun with libkrun TAP support
#
#####
FROM quay.io/fedora/fedora:44 AS crun-builder

ADD https://github.com/containers/crun/releases/download/1.28/crun-1.28.tar.zst \
    /tmp/crun-1.28.tar.zst
COPY patches/crun/0001-krun-add-tap-network-annotation.patch /tmp/

RUN dnf install -y --setopt=install_weak_deps=False \
        autoconf automake criu-devel gcc git-core glibc-static gperf \
        json-c-devel libcap-devel libkrun-devel libseccomp-devel libtool \
        make patch protobuf-c-devel python python3-libmount systemd-devel \
        wasmedge-devel zstd

RUN /bin/bash -c 'set -euo pipefail; \
    echo "62b82f7db89df3652970d9ad76f635a177d09bcb543c8d1dae13a749cd3e6e35  /tmp/crun-1.28.tar.zst" \
        | sha256sum --check --strict; \
    mkdir /tmp/crun; \
    tar --extract --zstd --file /tmp/crun-1.28.tar.zst \
        --directory /tmp/crun --strip-components=1; \
    cd /tmp/crun; \
    patch --batch --forward -p1 \
        < /tmp/0001-krun-add-tap-network-annotation.patch; \
    ./autogen.sh; \
    ./configure --disable-silent-rules --with-libkrun --with-wasmedge \
        --enable-embedded-blake3; \
    make -j "$(nproc)"; \
    install -D -m 0755 crun /out/usr/bin/crun; \
    /out/usr/bin/crun --version | grep -F "crun version 1.28"; \
    strings /out/usr/bin/crun | grep -Fx "krun.tap_name"'

#####
#
#  Stage 2: Pull SOPS binary
#
#####
FROM ghcr.io/getsops/sops:v3.13.3@sha256:857f5a151ac0b2bfc55c1e4e5581d66fb8e268e4d106b38e74191f3bac9d58ea as sops


#####
#
#  Stage 3: Pull prebuilt ZFS kmods
#
#####
FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms
ARG KERNEL_VERSION
ARG ZFS_VERSION


#####
# 
#  Stage 4: Final image
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
COPY --from=sops /usr/local/bin/sops /usr/local/bin/sops

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/prometheus 0755 prometheus prometheus -" \
      "d /var/lib/prometheus/node-exporter 0755 prometheus prometheus -" \
      > /usr/lib/tmpfiles.d/prometheus-node-exporter.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/nas-secrets 0700 root root -" \
      > /usr/lib/tmpfiles.d/nas-secrets.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    semodule -i /usr/share/selinux/targeted/gssproxy-local.cil; \
    semodule -i /usr/share/selinux/targeted/nas-krun-tun.cil'

RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    /bin/bash -c 'set -euo pipefail; \
    # Validate that provided kernel version matches actual CoreOS kernel \
    [[ "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")" == "${KERNEL_VERSION}" ]]; \
    arch="$(rpm -qa kernel --queryformat "%{ARCH}")"; \
    dnf install -y \
        crun-krun \
        jq \
        nftables \
        node-exporter \
        smartmontools \
        systemd-networkd \
        tailscale \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm \
        /zfs-rpms/*."${arch}".rpm; \
    depmod -a "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")"; \
    echo "zfs" > /etc/modules-load.d/zfs.conf; \
    rm -rf /var/lib/pcp /var/cache/dnf; \
    mapfile -t account_units < <( \
        awk "!/^#/" /usr/share/custom-coreos/fleet/account-units.list \
    ); \
    systemctl enable \
        "${account_units[@]}" \
        bootc-fetch-apply-updates.timer \
        nftables.service \
        nas-krun-network-policy.service \
        prepare-caddy-state.service \
        systemd-networkd.service \
        tailscaled.service \
        sops-distribute-secrets.service \
        zfs-create-garage-datasets.service \
        zfs-create-victoria-metrics-dataset.service \
        zfs-prepare-jellyfin-storage.service \
        zfs-scrub-monthly@tank.timer \
        zfs-snapshots-frequently@videos.timer \
        zfs-snapshots-hourly@videos.timer \
        zfs-snapshots-daily@videos.timer \
        zfs-snapshots-weekly@videos.timer \
        zfs-snapshots-monthly@videos.timer \
        zfs-snapshots-yearly@videos.timer \
        disk-health-metrics.timer \
        node_exporter.service; \
    systemctl disable systemd-networkd-wait-online.service; \
    systemctl disable zincati.service; \
    systemctl disable fwupd-refresh.timer; \
    dnf clean all; \
    rm -rf /var/log/dnf*'

COPY --from=crun-builder /out/usr/bin/crun /usr/bin/crun

RUN /bin/bash -c 'set -euo pipefail; \
    [[ "$(rpm -E "%{fedora}")" == "44" ]]; \
    [[ "$(rpm -q --queryformat "%{VERSION}" crun)" == "1.28" ]]; \
    [[ "$(readlink /usr/bin/krun)" == "crun" ]]; \
    /usr/bin/crun --version | grep -F "crun version 1.28"; \
    grep -aFq "krun.tap_name" /usr/bin/crun; \
    restorecon -F /usr/bin/crun'

RUN /bin/bash -c 'set -euo pipefail; \
    mapfile -t image_assets < <( \
        awk "NF && !/^#/" /usr/share/custom-coreos/fleet/assets.list \
    ); \
    for asset in "${image_assets[@]}"; do \
        semanage fcontext -a -t container_file_t -r s0 "${asset}(/.*)?"; \
        restorecon -F -R -- "${asset}"; \
    done'

RUN ["bootc", "container", "lint"]

LABEL containers.bootc=1
LABEL ostree.bootable=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
