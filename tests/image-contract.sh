#!/usr/bin/env bash
# ABOUTME: Runs read-only assertions inside the exact bootc image produced by a build.
set -euo pipefail

readonly expected_kernel="${1:?expected kernel version is required}"
readonly expected_zfs="${2:?expected ZFS version is required}"

actual_kernel="$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
actual_zfs="$(rpm -q zfs --queryformat '%{VERSION}')"
[[ "${actual_kernel}" == "${expected_kernel}" ]]
[[ "${actual_zfs}" == "${expected_zfs}" ]]
modinfo -k "${expected_kernel}" zfs >/dev/null

bootc container lint
[[ -d /usr/local && ! -L /usr/local ]]
[[ "$(readlink /usr/bin/krun)" == "crun" ]]
/usr/bin/crun --version | grep -Fq 'crun version 1.28'
grep -aFq 'krun.tap_name' /usr/bin/crun
/usr/local/bin/sops --version | grep -Fq 'sops 3.13.3'

semodule -l | grep -Eq '^gssproxy-local[[:space:]]'
semodule -l | grep -Eq '^nas-krun-tun[[:space:]]'

systemd-analyze verify \
    /usr/lib/systemd/system/ensure-nas-*.service \
    /usr/lib/systemd/system/nas-*.service \
    /usr/lib/systemd/system/prepare-caddy-state.service \
    /usr/lib/systemd/system/sops-distribute-secrets.service \
    /usr/lib/systemd/system/zfs-*.service \
    /usr/lib/systemd/system/disk-health-metrics.service
systemd-sysusers --dry-run --root=/
systemd-tmpfiles --create --dry-run --root=/
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun \
    >/dev/null

while IFS= read -r unit; do
    [[ -z "${unit}" || "${unit}" == \#* ]] && continue
    [[ "$(systemctl is-enabled "${unit}")" == "enabled" ]]
done < /usr/share/custom-coreos/fleet/account-units.list

while IFS= read -r unit; do
    [[ -z "${unit}" || "${unit}" == \#* ]] && continue
    [[ "$(systemctl is-enabled "${unit}")" == "enabled" ]]
done < /usr/share/custom-coreos/fleet/storage-units.list

for unit in \
    bootc-fetch-apply-updates.timer \
    disk-health-metrics.timer \
    nas-krun-network-policy.service \
    nftables.service \
    node_exporter.service \
    sops-distribute-secrets.service \
    systemd-networkd.service \
    tailscaled.service \
    zfs-prepare-jellyfin-storage.service; do
    [[ "$(systemctl is-enabled "${unit}")" == "enabled" ]]
done

for unit in fwupd-refresh.timer systemd-networkd-wait-online.service zincati.service; do
    [[ "$(systemctl is-enabled "${unit}")" == "disabled" ]]
done

[[ ! -e /tests ]]
[[ ! -e /docs ]]
[[ ! -e /quadlets ]]
[[ ! -e /usr/share/custom-coreos/tests ]]
[[ ! -e /usr/share/custom-coreos/history ]]
