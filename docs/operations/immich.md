# Immich deployment and first-use review

## Deployment contract

Immich v3.1.0 runs as four rootless libkrun guests:

| Component | UID | TAP address | Resources | Persistent state |
| --- | ---: | --- | --- | --- |
| server | 51130 | `10.253.10.2` | 4 vCPU, 4 GiB | library, thumbnails, encoded video |
| PostgreSQL | 51140 | `10.253.11.2` | 2 vCPU, 2 GiB | database |
| Valkey | 51150 | `10.253.12.2` | 1 vCPU, 512 MiB | queue/cache data |
| machine learning | 51160 | `10.253.13.2` | 4 vCPU, 4 GiB | rebuildable model/config caches |

All containers follow Immich's rootless UID 1000 contract through generated
`keep-id` namespaces. They use the upstream rootless hardening settings and
CPU-only processing; no host GPU is exposed. PostgreSQL gets the upstream
recommended 128 MiB shared-memory allocation and HDD-oriented configuration.

Only the server is host-published, on loopback TCP 2283. Caddy exposes it as
`https://photos.i.samhclark.com`. PostgreSQL, Valkey, and machine learning have
only generated inter-TAP consumer edges. The database password is encrypted in
SOPS and delivered as separate per-service runtime files.

## Storage and recovery classification

- `tank/immich-server/library` mounted at `/data` is authoritative. It includes
  uploaded originals, the managed library, profiles, and Immich's built-in
  database-backup directory.
- `tank/immich-database/data` is the live PostgreSQL database. It uses
  `recordsize=32K`, LZ4 compression, `atime=off`, and normal ARC data caching.
  This follows current OpenZFS PostgreSQL guidance while retaining PostgreSQL's
  default full-page-write safety and Immich's HDD I/O profile. Its mount is
  private `0700` state, matching PostgreSQL's data-directory initialization.
- `tank/immich-server/thumbs` and `tank/immich-server/encoded-video` are
  regenerable derivatives split out so a future off-site policy can exclude
  them.
- Valkey uses `/var/lib/immich/valkey` on the persistent root filesystem rather
  than a ZFS dataset. The official rootless deployment persists `/data`, but
  Immich's standard deployment treats Valkey as disposable. Keeping the small
  queue/cache directory makes restarts smoother without making it an
  authoritative recovery input.
- Machine-learning state remains persistent for smooth restarts but is not an
  authoritative recovery input.

No off-site replication is enabled by this deployment. See the discussion-only
[`../proposals/application-backups.md`](../proposals/application-backups.md).

## Image compatibility preflight

PostgreSQL uses Immich's public-source companion image because it packages the
exact PostgreSQL, pgvector, VectorChord, and tuning contract supported by this
Immich release. Valkey uses the official upstream image. Both remain pinned by
digest and run as UID 1000; there is no local companion-image release train.

After changing either image digest or its user/entrypoint settings, run the
networked, opt-in compatibility smoke before deployment:

```bash
make smoke-immich-images
```

This initializes disposable PostgreSQL state with checksums and requires both
PostgreSQL and Valkey to answer under their declared users. It deliberately
tests the external image boundary outside canonical offline `make check` and
`make test`.

## First use

On first successful deployment, open `https://photos.i.samhclark.com` and
create the initial administrator through Immich's setup screen. Afterward,
review Administration settings and confirm the external domain. Do not upload
the only copy of important photos until database backup output and a restore
procedure have been reviewed.

## Operator verification

Agents do not run these commands on the NAS. After the scheduled image update,
the operator can run `nas-diagnose-immich` for a comprehensive, secret-safe,
read-only report, or use this short verification:

```bash
( cd / &&
  for spec in \
    '_nas_immichserver 51130 immich-server.service' \
    '_nas_immichdatabase 51140 immich-database.service' \
    '_nas_immichvalkey 51150 immich-valkey.service' \
    '_nas_immichmachinelearning 51160 immich-machine-learning.service'; do
    read -r user uid unit <<<"${spec}"
    sudo systemctl is-active "user@${uid}.service"
    sudo runuser -u "${user}" -- env \
      HOME="/var/home/${user}" \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
      systemctl --user is-active "${unit}"
  done
)
curl --fail --silent --show-error \
  http://127.0.0.1:2283/api/server/ping
curl --fail --silent --show-error \
  https://photos.i.samhclark.com/api/server/ping
```

Both HTTP requests should return a JSON pong response. If they do not, inspect
only the affected user unit before changing state, for example:

```bash
sudo journalctl --unit user@51130.service --boot --lines 100 --no-pager
```

If `nas-prepare-immich-database-storage.service` requests an explicit repair,
first confirm `immich-database.service` is stopped and inspect the reported
ownership, mode, and labels. To authorize the bounded reconciliation without
deleting or reinitializing PostgreSQL, create
`/var/lib/nas-repairs/immich-database/repair-required` and restart the storage
preparation unit. The runtime refuses mutation while the container is running
and consumes the marker only after all postconditions pass. Then restart the
database user unit followed by the server user unit.

The review step is read-only:

```bash
( cd / &&
  sudo runuser -u _nas_immichdatabase -- env \
    HOME=/var/home/_nas_immichdatabase \
    XDG_RUNTIME_DIR=/run/user/51140 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51140/bus \
    systemctl --user is-active immich-database.service
)
sudo systemctl status nas-prepare-immich-database-storage.service --no-pager
sudo stat -c '%U:%G %a %C %n' /var/lib/immich/database
```

Only after confirming the database service is not active, this state-changing
sequence authorizes one bounded repair and retries the two affected services:

```bash
( cd / &&
  sudo install -d -m 0755 -o root -g root \
    /var/lib/nas-repairs/immich-database &&
  sudo install -m 0600 -o root -g root /dev/null \
    /var/lib/nas-repairs/immich-database/repair-required &&
  sudo systemctl restart nas-prepare-immich-database-storage.service &&
  sudo test -r /run/nas-storage/immich-database/ready &&
  sudo runuser -u _nas_immichdatabase -- env \
    HOME=/var/home/_nas_immichdatabase \
    XDG_RUNTIME_DIR=/run/user/51140 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51140/bus \
    systemctl --user restart immich-database.service &&
  sudo runuser -u _nas_immichserver -- env \
    HOME=/var/home/_nas_immichserver \
    XDG_RUNTIME_DIR=/run/user/51130 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51130/bus \
    systemctl --user restart immich-server.service
)
```
