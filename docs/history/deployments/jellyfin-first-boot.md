# Jellyfin First-Boot Validation

> **Archived evidence — not authoritative.** This first-deployment procedure
> is complete. Do not execute it against the current NAS.

Run these checks after the NAS first boots the image containing Jellyfin.

The first storage-preparation run may take a while because it must relabel the
existing media tree from `unlabeled_t` to `container_file_t:s0`. It does not
change media contents or ownership.

## 1. Watch storage preparation

Check its current state:

```bash
sudo systemctl status zfs-prepare-jellyfin-storage.service --no-pager
```

Follow its log:

```bash
sudo journalctl -fu zfs-prepare-jellyfin-storage.service
```

During the initial relabel, expect:

```text
Restoring shared container SELinux labels under /var/zfs/tank/videos; this first pass may take a while
```

Do not restart the service while `restorecon` is running. Success ends with:

```text
Jellyfin ZFS storage and read-only media access are ready
```

Press Ctrl-C to leave `journalctl -f`, then verify readiness:

```bash
sudo systemctl status zfs-prepare-jellyfin-storage.service --no-pager
sudo test -e /run/jellyfin-storage/ready && echo "Jellyfin storage ready"
```

The unit should be `active (exited)` and the second command should print
`Jellyfin storage ready`.

## 2. Validate identity and datasets

```bash
getent passwd _nas_jellyfin
grep '^_nas_jellyfin:' /etc/subuid /etc/subgid
loginctl show-user _nas_jellyfin -p Linger -p State

sudo zfs list -o name,mountpoint,recordsize,compression,atime \
  tank/videos \
  tank/jellyfin \
  tank/jellyfin/config \
  tank/jellyfin/cache

sudo stat -c '%U:%G %a %C %n' \
  /var/lib/jellyfin/config \
  /var/lib/jellyfin/cache \
  /var/zfs/tank/videos \
  /var/zfs/tank/videos/movies \
  /var/zfs/tank/videos/tv-shows
```

Expected results:

- `_nas_jellyfin` has UID/GID `51120`.
- Config and cache are mounted from `tank/jellyfin/config` and
  `tank/jellyfin/cache`.
- Config and cache are owned by `_nas_jellyfin`, mode `0750`.
- Every listed path is labeled `container_file_t:s0`.
- Media remains owned by `1000:1000`.

## 3. Validate the rootless service

```bash
sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin \
  XDG_RUNTIME_DIR=/run/user/51120 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51120/bus \
  systemctl --user status jellyfin.service --no-pager
```

The service should be active/running.

Confirm libkrun and the image:

```bash
sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin \
  XDG_RUNTIME_DIR=/run/user/51120 \
  podman inspect jellyfin --format \
  'runtime={{.OCIRuntime}} status={{.State.Status}} network={{.HostConfig.NetworkMode}} image={{.ImageName}} annotations={{json .Config.Annotations}} health={{json .Config.Healthcheck}}'
```

Expect `runtime=krun`, `status=running`, `network=host`, the annotation
`krun.tap_name=krun-51120`, and no executable healthcheck. Jellyfin's image
healthcheck uses `podman exec`, which the krun handler does not support, so the
Quadlet disables it; the external blackbox health probe is authoritative.

Inspect the mounts:

```bash
sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin \
  XDG_RUNTIME_DIR=/run/user/51120 \
  podman inspect jellyfin --format \
  '{{range .Mounts}}{{println .Source "->" .Destination .Options}}{{end}}'
```

Expected media mounts:

```text
/var/zfs/tank/videos/movies -> /media/movies
/var/zfs/tank/videos/tv-shows -> /media/tv-shows
```

Both media mounts must be read-only. Config and cache must be writable.

## 4. Validate networking and Caddy

```bash
curl -fsS http://127.0.0.1:8096/health
curl -fsS https://jellyfin.i.samhclark.com/health
sudo nft list chain ip nas_krun_nat output | grep 'tcp dport 8096'
sudo ss -H -ltnp | grep ':8096\b' || echo 'expected: no host socket on 8096'
```

Both health requests should return `Healthy`. There should be no host socket
for 8096; the nftables output chain should DNAT loopback traffic to
`10.253.2.2:8096`.

If local health works but HTTPS does not, inspect Caddy:

```bash
sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy \
  XDG_RUNTIME_DIR=/run/user/51310 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
  systemctl --user status caddy.service --no-pager

sudo journalctl _UID=51310 -b --no-pager | tail -100
```

## 5. Complete the setup wizard

Open this URL in a browser:

```text
https://jellyfin.i.samhclark.com
```

In the first-run wizard:

1. Create the administrator account.
2. Add a Movies library using `/media/movies`.
3. Add a Shows library using `/media/tv-shows`.
4. Leave hardware acceleration disabled for now.

Confirm both libraries scan successfully and artwork and metadata begin to
appear.

## 6. Test playback

Test at least:

- one movie;
- one TV episode;
- seeking forward and backward;
- subtitles, if available;
- a client or bitrate setting that causes transcoding.

Transcoding is software-based in this deployment. Inspect the Jellyfin journal
for playback or FFmpeg errors:

```bash
sudo journalctl _UID=51120 -b --no-pager | tail -200
```

## 7. Validate monitoring

Wait at least one minute after Jellyfin becomes healthy, then run:

```bash
curl -G -fsS http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="jellyfin-health",service="jellyfin"}' \
  | jq .

curl -G -fsS http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=up{job="jellyfin-health"}' \
  | jq .
```

Both query results should contain a sample value of `"1"`.

## 8. Validate a second boot

After completing setup and an initial playback test:

```bash
sudo systemctl reboot
```

After reconnecting:

```bash
sudo systemctl status zfs-prepare-jellyfin-storage.service --no-pager
sudo journalctl -u zfs-prepare-jellyfin-storage.service -b --no-pager
curl -fsS http://127.0.0.1:8096/health
curl -fsS https://jellyfin.i.samhclark.com/health
```

The second storage-preparation run should be quick and should not log another
recursive media relabel. Finally, verify in the web UI that the administrator
account, libraries, scan state, and metadata survived the reboot.
