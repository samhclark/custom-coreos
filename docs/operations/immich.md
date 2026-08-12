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
  default full-page-write safety and Immich's HDD I/O profile.
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

## First use

On first successful deployment, open `https://photos.i.samhclark.com` and
create the initial administrator through Immich's setup screen. Afterward,
review Administration settings and confirm the external domain. Do not upload
the only copy of important photos until database backup output and a restore
procedure have been reviewed.

## Operator verification

Agents do not run these commands on the NAS. After the scheduled image update,
the operator can verify the deployment with this read-only command:

```bash
for uid in 51130 51140 51150 51160; do
  sudo systemctl is-active "user@${uid}.service"
done
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
