# Rootless Garage Rollout Checklist

Use this after the NAS boots an image containing the rootless Garage cutover.
The expected host identity is `_nas_garage` with UID/GID `51110`; the user
Quadlet lives under `/etc/containers/systemd/users/51110/garage.container`.

Status: completed and production-validated on 2026-07-20. Every success
criterion below passed on the NAS.

Deploy this release through a reboot. Do not switch the running rootful service
in place. On the first rootless boot, the host preparation service verifies the
completed preflight, creates the coordinated recursive snapshot
`tank/garage@pre-rootless-v1`, and changes both ZFS trees to UID/GID `51110`.
It changes each dataset root last, so an interrupted migration remains visibly
incomplete and retries without publishing the readiness marker.

## Success Criteria

- no system-manager Garage service or running rootful Garage container remains
- `_nas_garage`, its subordinate IDs, linger state, and user manager exist
- all three runtime secret files are readable only by `_nas_garage`
- the metadata and data paths remain on their exact datasets, owned by
  UID/GID `51110`, mode `0750`, and labeled `container_file_t:s0`
- the saved node ID, layout, buckets, and keys are unchanged
- ports `3900`, `3902`, and `3903` listen only on loopback; host port `3901`
  remains closed
- Garage health, VictoriaMetrics scraping, blackbox probing, Caddy routing,
  and the Garage Grafana dashboard remain healthy

## 1. Rootful Retirement

```bash
test ! -e /etc/containers/systemd/garage.container
if systemctl list-unit-files garage.service --no-legend |
    grep -q '^garage.service'; then
  echo 'ERROR: retired system Garage unit still exists' >&2
  exit 1
fi
sudo podman ps --filter name=garage
test ! -e /etc/profile.d/50_garage.sh || sudo rm /etc/profile.d/50_garage.sh
```

The rootless Quadlet also refuses to start when the retired rootful source file
exists or one of Garage's host ports is already occupied. If this gate fails,
do not manually start either container. Confirm the stale file came from the
old image, remove it, and reboot again.

## 2. Identity And User Manager

```bash
getent passwd _nas_garage
getent group _nas_garage
grep '^_nas_garage:' /etc/subuid /etc/subgid
loginctl show-user _nas_garage -p Linger -p State
systemctl status user@51110.service --no-pager
```

Expected subordinate-ID entries:

```text
_nas_garage:511100000:65536
```

## 3. Storage Migration

```bash
sudo systemctl status zfs-create-garage-datasets.service --no-pager
sudo journalctl -u zfs-create-garage-datasets.service -b --no-pager
test -e /run/garage-datasets/ready
test -e /var/lib/nas-migrations/garage-rootless-ownership-v1/complete
findmnt -no SOURCE,TARGET -T /var/lib/garage/meta
findmnt -no SOURCE,TARGET -T /var/lib/garage/data
stat -c '%U:%G %a %n' /var/lib/garage/meta /var/lib/garage/data
ls -Zd /var/lib/garage/meta /var/lib/garage/data
sudo zfs list -r -t snapshot -o name,used,refer,creation tank/garage |
  grep '@pre-rootless-v1$'
```

Both paths must have owner `_nas_garage:_nas_garage`, mode `0750`, and the
SELinux context `container_file_t:s0`. The snapshot listing must contain the
parent, metadata, and data snapshots with the same fixed name.

The preparation unit has no timeout and retries every 30 seconds. On normal
boots it checks only the dataset roots and one immediate descendant from each
tree; it does not recursively scan the object store. The user service waits up
to one hour for its current-boot marker, exact mounts, owners, and write access.
If `tank` was imported late, let the automatic retry recover; otherwise restart
only the preparation unit and inspect its journal.

A recursive ownership and SELinux repair is deliberately explicit because it
can take tens of minutes. With Garage stopped, request one by creating the
durable marker and restarting the preparation unit:

```bash
sudo -u _nas_garage env \
  HOME=/var/home/_nas_garage \
  XDG_RUNTIME_DIR=/run/user/51110 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51110/bus \
  bash -lc 'cd / && systemctl --user stop garage.service'
sudo install -d -m 0700 -o root -g root \
  /var/lib/nas-migrations/garage-rootless-ownership-v1
sudo touch \
  /var/lib/nas-migrations/garage-rootless-ownership-v1/repair-required
sudo systemctl restart zfs-create-garage-datasets.service && \
sudo -u _nas_garage env \
  HOME=/var/home/_nas_garage \
  XDG_RUNTIME_DIR=/run/user/51110 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51110/bus \
  bash -lc 'cd / && systemctl --user start garage.service'
```

The marker is removed only after both complete recursive passes succeed. Do
not start Garage manually while the preparation service is running; the
foreground `systemctl restart` must return successfully first.

## 4. Runtime Secrets

```bash
sudo systemctl status sops-distribute-secrets.service --no-pager
sudo stat -c '%U:%G %a %s %n' \
  /run/nas-secrets/garage \
  /run/nas-secrets/garage/garage-rpc-secret \
  /run/nas-secrets/garage/garage-admin-token \
  /run/nas-secrets/garage/garage-metrics-token
sudo -u _nas_garage test -r /run/nas-secrets/garage/garage-rpc-secret
sudo -u _nas_garage test -r /run/nas-secrets/garage/garage-admin-token
sudo -u _nas_garage test -r /run/nas-secrets/garage/garage-metrics-token
```

The directory should be `root:_nas_garage` mode `0710`; each file should be
`_nas_garage:_nas_garage` mode `0400`. Do not print their values. The rootful
Garage Podman secrets are intentionally retired; Caddy's `cf-api-token`
remains rootful.

## 5. Service, Identity, And Logs

```bash
systemctl status garage.service --no-pager
sudo -u _nas_garage env \
  HOME=/var/home/_nas_garage \
  XDG_RUNTIME_DIR=/run/user/51110 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51110/bus \
  bash -lc 'cd / && systemctl --user status garage.service --no-pager && podman ps --no-trunc'

garage node id
garage status
garage layout show
garage bucket list
garage key list

sudo journalctl _UID=51110 SYSLOG_IDENTIFIER=garage -b --no-pager
sudo journalctl _UID=51110 -b --no-pager
```

The system-manager status should find no Garage unit. Compare the CLI output
with `/var/lib/nas-migrations/garage-rootless-preflight-v1/`; the node ID,
layout, and stored resources must not change. The `garage` wrapper deliberately
runs from `/`, so it works even when the caller's current directory is not
searchable by `_nas_garage`.

An existing login shell may retain the retired `garage` alias. Start a new
shell or run `unalias garage` once before testing the wrapper.

## 6. Ports And Monitoring

```bash
curl -fsS http://127.0.0.1:3903/health
sudo ss -ltnp | grep -E ':390[0-3]\b'
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="garage-health"}' |
  jq -e '.status == "success" and any(.data.result[]; .value[1] == "1")'
```

Only loopback listeners `3900`, `3902`, and `3903` should appear. Check the
Garage dashboard in Grafana for fresh samples. The direct Garage `/metrics`
scrape can still be slow; service availability remains based on the blackbox
health probe.

Health and metrics do not prove object reads and writes. When a disposable
bucket and existing S3 client profile are available, finish with an upload,
download, byte comparison, and deletion through the Caddy S3 endpoint.

## 7. Cleanup After Validation

Keep the rollback snapshot until identity, health, monitoring, and an existing
object read have been verified. Then remove it so future writes do not retain
pre-migration ZFS blocks indefinitely:

```bash
sudo zfs destroy -r tank/garage@pre-rootless-v1
```

After the rootless deployment is confirmed, these old rootful artifacts can be
removed if they remain locally:

```bash
sudo podman rm --ignore garage
test ! -e /etc/garage/garage.toml || sudo rm /etc/garage/garage.toml
```

The saved preflight report is small and may be retained as migration evidence.
Its timer, service, and executable are no longer present in the image.

## Rollback

A bootc rollback alone does not require reversing ownership: the old rootful
container can access UID `51110` files, and its SOPS manifest recreates the
rootful Podman secrets at boot. If that deployment writes new `0:0` files,
create the `repair-required` marker before returning Garage to service on the
rootless image. Normal boots intentionally do not search the entire object
store for deep ownership drift.

For a data rollback while remaining on the rootless image, use this sequence:

```bash
sudo -u _nas_garage env \
  HOME=/var/home/_nas_garage \
  XDG_RUNTIME_DIR=/run/user/51110 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51110/bus \
  bash -lc 'cd / && systemctl --user stop garage.service'
sudo systemctl stop garage.service 2>/dev/null || true
sudo zfs rollback tank/garage/meta@pre-rootless-v1
sudo zfs rollback tank/garage/data@pre-rootless-v1
sudo systemctl restart zfs-create-garage-datasets.service
sudo -u _nas_garage env \
  HOME=/var/home/_nas_garage \
  XDG_RUNTIME_DIR=/run/user/51110 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51110/bus \
  bash -lc 'cd / && systemctl --user start garage.service'
```

Keep both Garage services stopped while rolling metadata and data back to the
matching snapshots. A ZFS rollback is not atomic across datasets. The commands
above fail rather than destroy newer snapshots; review and preserve any newer
snapshots instead of casually adding `-r`. Dataset preparation reapplies
ownership and labels before the user service can pass its readiness gate. The
pre-rootless snapshots restore root-owned dataset roots, which automatically
selects the interrupted-repair path; other rollback points may require the
explicit `repair-required` marker.
