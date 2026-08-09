# Jellyfin Deployment Checklist

> **Archived evidence — not authoritative.** This first-deployment checklist
> is complete. Do not execute it against the current NAS.

Use this after the NAS first boots the image containing Jellyfin. The service
runs as `_nas_jellyfin` (UID/GID `51120`) in a rootless libkrun guest. Caddy
publishes it at `https://jellyfin.i.samhclark.com`; port 8096 remains published
on host loopback only through nftables DNAT. Both services use dedicated
root-managed TAPs and routed nftables policy, avoiding TSI stream
head-of-line blocking.

The storage preparation unit creates `tank/jellyfin/{config,cache}`. It does
not create, move, rename, or change ownership of the existing `tank/videos`
media dataset. It requires that dataset to be mounted at
`/var/zfs/tank/videos`, adds
a persistent shared `container_file_t:s0` policy, and may perform one long
recursive SELinux relabel on the first deployment. Jellyfin receives the media
tree read-only.

Hardware transcoding and UDP discovery are intentionally disabled in this
first deployment. Playback uses direct streaming or CPU transcoding inside a
4-vCPU, 4-GiB libkrun guest.

## Storage preparation

```bash
sudo systemctl status zfs-prepare-jellyfin-storage.service --no-pager
sudo journalctl -u zfs-prepare-jellyfin-storage.service -b --no-pager
sudo zfs list -o name,mountpoint,recordsize,compression,atime \
  tank/videos tank/jellyfin tank/jellyfin/config tank/jellyfin/cache
sudo stat -c '%U:%G %a %C %n' \
  /var/lib/jellyfin/config /var/lib/jellyfin/cache \
  /var/zfs/tank/videos \
  /var/zfs/tank/videos/movies \
  /var/zfs/tank/videos/tv-shows
```

The service must be active/exited with `/run/jellyfin-storage/ready` present.
The two writable roots should be owned by `51120:51120`, mode `0750`, and all
three roots should have `container_file_t:s0`. If preparation reports that
`_nas_jellyfin` cannot read the media tree, fix only the required read/traverse
permissions; do not chown the media library to Jellyfin.

## Rootless service and health

```bash
getent passwd _nas_jellyfin
grep '^_nas_jellyfin:' /etc/subuid /etc/subgid
loginctl show-user _nas_jellyfin -p Linger -p State

sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin \
  XDG_RUNTIME_DIR=/run/user/51120 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51120/bus \
  systemctl --user status jellyfin.service --no-pager

curl -fsS http://127.0.0.1:8096/health
curl -fsS https://jellyfin.i.samhclark.com/health
sudo nft list chain ip nas_krun_nat output | grep 'tcp dport 8096'
sudo ss -H -ltnp | grep ':8096\b' || echo 'expected: no host socket on 8096'

sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin \
  XDG_RUNTIME_DIR=/run/user/51120 \
  podman inspect jellyfin --format \
  'runtime={{.OCIRuntime}} network={{.HostConfig.NetworkMode}} health={{json .Config.Healthcheck}} annotations={{json .Config.Annotations}}'
```

Both health requests should return `Healthy`. There should be no host socket
for 8096; the nftables output chain should DNAT loopback traffic to
`10.253.2.2:8096`. Inspect output should show `runtime=krun`, `network=host`,
the `krun.tap_name=krun-51120` annotation, and no executable image
healthcheck. The blackbox probe, not Podman's container-health state, is
authoritative. Complete Jellyfin's first-run wizard at the HTTPS URL, create
the admin account, then add `/media/movies` and `/media/tv-shows` as separate
library roots.

## Monitoring and reboot

After the next VictoriaMetrics configuration reload/restart, confirm the
`jellyfin-health` blackbox target is fresh and `probe_success` is `1`. Reboot
once more, then repeat the storage, user-service, local-health, and HTTPS
checks. The preparation unit should only perform bounded label checks on a
steady-state boot.
