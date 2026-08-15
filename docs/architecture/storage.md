# Service storage architecture

`quadlets/<service>.toml` is the only authored description of application
storage. A storage declaration simultaneously defines the host lifecycle, the
container mount, the boot-time preparation unit, and the rootless service's
current-boot readiness check. Raw `[[container.volumes]]` sources below `/var`
are rejected.

This follows the useful part of Android's application model: each service has
a stable identity, explicitly declares the state it can see, and receives only
the derived mounts and host preparation needed for that declaration. The
generator acts as a small policy compiler rather than relying on each service
to reproduce filesystem setup correctly.

## Storage kinds

`kind = "directory"` creates a service-owned directory below `/var`. Optional
subdirectories are explicit. These small root-filesystem trees use guarded
automatic ownership and SELinux repair.

`kind = "managed-zfs"` creates a dataset below `tank/<service>/` only when it
is absent. Record size, compression, atime, primary-cache policy, mountpoint,
owner, mode, and persistent `container_file_t:s0` labeling are explicit. An
existing dataset is verified; properties are never changed in place.

`kind = "existing-zfs"` requires the shared `tank/videos` dataset. It is
read-only by construction. The storage runtime may repair its SELinux labels
after an explicit request, but it never creates the dataset or changes its
ownership or modes.

Every `[[storage.exports]]` names a relative source, an absolute container
path, and `read-only` or `read-write` access. Generated Quadlets do not use
Podman `:z` or `:Z` for these trees.

## Generated enforcement

The compiler derives four artifacts from the typed declaration:

- `Volume=` entries in the rootless Quadlet;
- `/usr/share/custom-coreos/storage/<service>.storage-manifest`;
- `nas-prepare-<service>-storage.service`;
- a bounded `ExecStartPre` check of `/run/nas-storage/<service>/ready`, exact
  ZFS mount sources, service ownership, and service-user access.

`fleet/storage-units.list` is the Containerfile enablement source. Adding
storage never requires a second handwritten unit list.

The runtime parses its manifest completely before inspecting or changing the
host. Directory-only services do not require ZFS. ZFS use is restricted to
`zpool list` and `zfs list`, `get`, and `create`; pool creation/import/export,
dataset destruction, rollback, property mutation, and snapshot retention are
outside this engine. Snapshot expiry remains a separate, narrowly reviewed
unit because it intentionally destroys only expired snapshots.

Owned storage roots require the service's exact host UID/GID, declared mode,
and canonical `system_u:object_r:container_file_t:s0` context. The bounded
descendant sample has a different contract because rootless user namespaces
can legitimately create files as either the service host UID/GID or an ID in
that service's generated 65,536-ID subordinate range. Its SELinux user field
may also differ; readiness enforces the security-relevant
`object_r:container_file_t:s0` suffix and rejects MCS categories. IDs outside
the service identity and assigned subordinate range, wrong SELinux types, and
non-`s0` ranges remain drift.

## Repair policy

Normal boot performs root and one-descendant checks, not unbounded scans.
Small directory state is repaired automatically only after the service's
rootless container is confirmed stopped and its declared TCP ports are free.

Established ZFS trees require an explicit durable request:

```text
/var/lib/nas-repairs/<service>/repair-required
```

New empty managed datasets initialize automatically. A private dataset root
left owned by `root:root` records an interrupted repair and resumes
automatically. The runtime arms every private root in the service group before
recursive work, removes the explicit request only after the whole group
passes, and publishes readiness last. Recursive traversals stay on one
filesystem, prune `.zfs`, and use `restorecon -F -R -x`.

An explicit-repair-required refusal exits with status 78. Generated storage
units declare that status in `RestartPreventExitStatus`, so deterministic
operator intervention does not become a 30-second retry loop; transient
failures retain the existing restart policy. Drift logs name the exact sampled
path and observed ownership, mode, or label before refusing repair.

The current stateful services are Caddy, Alertmanager, Grafana, Garage,
VictoriaMetrics, Jellyfin, and all four Immich components. Blackbox exporter,
vmalert, and Jellyfin exporter are intentionally stateless; image assets and
runtime secrets are separate declaration classes.
