# Garage Rootless Migration Preflight (Completed)

This is the historical record of Garage's first, rootful hardening release.
The NAS preflight completed successfully before the rootless cutover was
implemented. The second release removes the timer, service, and script described
below; the report remains under `/var/lib/nas-migrations/` for comparison. See
`docs/rootless-garage-checklist.md` for the current rollout procedure.

## What Ran

`zfs-create-garage-datasets.service` now:

- validates that both paths are mounted from the exact expected ZFS datasets
- fails closed if the persistent SELinux policy cannot be installed or the
  root/sample labels are not `container_file_t:s0`
- has no start timeout and retries after failures such as a late `tank` import
- publishes `/run/garage-datasets/ready` only after both datasets are prepared

Five minutes after boot, `garage-rootless-preflight.timer` started
`garage-rootless-preflight.service` outside the boot-critical target
transaction. The service records a one-time baseline under
`/var/lib/nas-migrations/garage-rootless-preflight-v1/`. It captures Garage's
node identity, version, status, layout, buckets, health, image, listeners, ZFS
properties, snapshots, pool capacity, dataset-root metadata, and full-tree
entry counts/ownership/SELinux checks.

The service creates a temporary coordinated recursive ZFS snapshot, scans the
stable snapshot trees, and removes the snapshot when finished. The full scans
may take a long time and add disk load, especially for `tank/garage/data`, but
they do not block boot completion or change file contents, modes, or ownership.
The hardened dataset-preparation service may repair SELinux xattrs if drift is
detected. A `complete` marker prevents the preflight from repeating on later
boots.

## First-Stage Check

```bash
sudo systemctl status zfs-create-garage-datasets.service --no-pager
sudo systemctl status garage.service --no-pager
sudo systemctl status garage-rootless-preflight.timer --no-pager
sudo systemctl status garage-rootless-preflight.service --no-pager
sudo journalctl -u garage-rootless-preflight.service -b --no-pager
```

The preflight may still be running when first checked. Wait for it to finish;
do not restart the NAS merely because the data scan is taking time.

After it succeeds, list the report without printing any secret values:

```bash
sudo find /var/lib/nas-migrations/garage-rootless-preflight-v1 \
  -maxdepth 1 -type f -printf '%f\n' | sort
sudo grep -H . \
  /var/lib/nas-migrations/garage-rootless-preflight-v1/{image,version,node-id,status,layout,buckets,health,mounts,datasets,properties,snapshots,pool,roots,listeners,meta-scan,data-scan}.txt
```

Expected results:

- `garage.service` is still a system service using the rootful Podman store
- health is successful and the recorded node/layout/bucket data matches the
  current deployment
- mount sources are `tank/garage/meta` and `tank/garage/data`
- dataset roots and all scanned entries are UID/GID `0:0`
- `first_unexpected_owner` and `first_unexpected_label` are empty
- both roots and scanned descendants use `container_file_t:s0`
- listeners `3900`, `3902`, and `3903` are loopback-only on the host; RPC
  `3901` is not published on the host

## Failure And Rerun

The service intentionally leaves no `complete` marker when a command or scan
fails. Inspect its journal and the partial report first. After correcting the
cause, rerun it with:

```bash
sudo systemctl reset-failed garage-rootless-preflight.service
sudo systemctl start garage-rootless-preflight.service
```

If `tank` was imported after the original boot transaction, restart the
dataset preparation and Garage before rerunning the preflight:

```bash
sudo systemctl restart zfs-create-garage-datasets.service
sudo systemctl restart garage.service
sudo systemctl start garage-rootless-preflight.service
```

To deliberately replace a successful report, remove only its completion
marker before starting the service again:

```bash
sudo rm -f /var/lib/nas-migrations/garage-rootless-preflight-v1/complete
sudo systemctl start garage-rootless-preflight.service
```

The successful report established that both trees were consistently owned by
`0:0` and labeled `container_file_t:s0`. The second release uses that evidence
before taking its permanent coordinated rollback snapshot and migrating
ownership.
