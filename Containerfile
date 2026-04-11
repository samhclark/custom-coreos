# Build arguments - all required, no defaults
ARG KERNEL_VERSION
ARG ZFS_VERSION
ARG AGE_PLUGIN_TPM_VERSION=v1.0.1
ARG AGE_PLUGIN_TPM_SHA256=ba5930cef12998e1bf5e979bcbb45e4e4cefdac773144b57f7e9e391c8c7e3fe

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
ARG AGE_PLUGIN_TPM_VERSION
ARG AGE_PLUGIN_TPM_SHA256

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
    printf "%s\n" \
      "d /var/lib/victoria-metrics 0755 root root -" \
      > /usr/lib/tmpfiles.d/victoria-metrics.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/alertmanager 0755 root root -" \
      "d /var/lib/alertmanager/data 0755 root root -" \
      > /usr/lib/tmpfiles.d/alertmanager.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/prometheus 0755 prometheus prometheus -" \
      "d /var/lib/prometheus/node-exporter 0755 prometheus prometheus -" \
      > /usr/lib/tmpfiles.d/prometheus-node-exporter.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    printf "%s\n" \
      "d /var/lib/age-tpm 0700 root root -" \
      "d /var/lib/podman-secrets 0700 root root -" \
      > /usr/lib/tmpfiles.d/podman-secret-driver.conf'

RUN /bin/bash -c 'set -euo pipefail; \
    curl -fsSL -o /tmp/age-plugin-tpm.tar.gz \
        "https://github.com/Foxboron/age-plugin-tpm/releases/download/${AGE_PLUGIN_TPM_VERSION}/age-plugin-tpm-${AGE_PLUGIN_TPM_VERSION}-linux-amd64.tar.gz"; \
    echo "${AGE_PLUGIN_TPM_SHA256}  /tmp/age-plugin-tpm.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/age-plugin-tpm.tar.gz -C /tmp; \
    install -m 0755 /tmp/age-plugin-tpm/age-plugin-tpm /usr/local/bin/age-plugin-tpm; \
    rm -rf /tmp/age-plugin-tpm.tar.gz /tmp/age-plugin-tpm'

RUN /bin/bash -c 'set -euo pipefail; \
    semodule -i /usr/share/selinux/targeted/gssproxy-local.cil'

RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    /bin/bash -c 'set -euo pipefail; \
    # Validate that provided kernel version matches actual CoreOS kernel \
    [[ "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")" == "${KERNEL_VERSION}" ]]; \
    arch="$(rpm -qa kernel --queryformat "%{ARCH}")"; \
    rpm -e --nodeps nfs-utils-coreos; \
    dnf install -y \
        age \
        cockpit-bridge \
        cockpit-kdump \
        cockpit-machines \
        cockpit-networkmanager \
        cockpit-ostree \
        cockpit-podman \
        cockpit-selinux \
        cockpit-storaged \
        cockpit-system \
        jq \
        nftables \
        node-exporter \
        smartmontools \
        tailscale \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm \
        /zfs-rpms/*."${arch}".rpm; \
    depmod -a "$(rpm -qa kernel --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")"; \
    echo "zfs" > /etc/modules-load.d/zfs.conf; \
    rm -rf /var/lib/pcp /var/cache/dnf; \
    systemctl enable \
        ensure-nas-grafana-account.service \
        age-tpm-identity.service \
        bootc-fetch-apply-updates.timer \
        nftables.service \
        tailscaled.service \
        garage-generate-secrets.service \
        zfs-create-garage-datasets.service \
        zfs-create-victoria-metrics-dataset.service \
        zfs-health-check.timer \
        zfs-scrub-monthly@tank.timer \
        zfs-snapshots-frequently@videos.timer \
        zfs-snapshots-hourly@videos.timer \
        zfs-snapshots-daily@videos.timer \
        zfs-snapshots-weekly@videos.timer \
        zfs-snapshots-monthly@videos.timer \
        zfs-snapshots-yearly@videos.timer \
        alertmanager-generate-config.service \
        disk-health-metrics.timer \
        node_exporter.service; \
    systemctl disable zincati.service; \
    dnf clean all; \
    rm -rf /var/log/dnf*'

RUN /bin/bash -c 'set -euo pipefail; \
    semanage fcontext -a -t container_file_t -r s0 "/usr/share/custom-coreos/grafana(/.*)?"; \
    semanage fcontext -a -t container_file_t -r s0 "/var/lib/grafana(/.*)?"; \
    restorecon -F -R /usr/share/custom-coreos/grafana'

RUN ["bootc", "container", "lint"]

LABEL containers.bootc=1
LABEL ostree.bootable=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
