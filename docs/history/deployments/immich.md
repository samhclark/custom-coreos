# Immich rollout retrospective

> Archived evidence — not authoritative. This records the rollout
> through commit `82b5705` and the reboot evidence collected on 2026-08-15; it
> contains no current operational procedure.

## Outcome

The rollout established a four-part Immich application on rootless libkrun:
server, PostgreSQL/VectorChord, Valkey, and CPU-only machine learning. The
application model, generated Quadlets, routed TAP networking, declarative ZFS
storage, SOPS runtime secrets, image smoke tests, and diagnostics were all
added between `9e26898` and `82b5705` (2026-08-11 through 2026-08-14).

The deployment was usable before the reboot, but reboot recovery was not
validated successfully. In the collected boot evidence, the database, Valkey,
and machine-learning services became ready; the server repeatedly restarted
behind `nas-prepare-immich-server-storage.service`, so host port 2283 was not
available. This is a storage-readiness failure, not evidence of a database,
network-policy, or all-components startup failure.

## What churn was avoidable

Some churn was preventable by making the first release gates match the actual
runtime boundary:

- The initial deployment should have included an image/user/entrypoint smoke
  test and a clean reboot test before being treated as complete. Those checks
  arrived later in `61e0186` and `82b5705`; they would have shortened the
  feedback loop.
- The storage runtime accepted a narrower ZFS `recordsize` vocabulary than the
  declared PostgreSQL contract. `32K` was added in `1fed545`; testing the full
  vocabulary in `5968996` was a useful correction, but the declaration and
  validator should have been derived or checked together initially.
- PostgreSQL's user and ownership contract took three revisions
  (`b15dfca`, `058d37d`, and `82b5705`). The external image's namespace-root
  behavior should have been established by the compatibility probe before
  choosing the Quadlet settings.
- The rollout introduced a fail-closed explicit-repair path, but its systemd
  restart policy turned a deterministic mismatch into a repeated 30-second
  retry storm. The reboot log records the same refusal through at least
  restart counter 39. Failure should be bounded and diagnostic rather than
  continuously noisy.

These are process and test-order problems, not reasons to remove the safety
gates. The application-model standardization in `9e26898`, the Immich service
and network expansion in `cdc8fec`, and the SELinux transaction correction in
`7f5252d` were broader platform work required to host this application class.

## What was runtime discovery

The remaining iterations reflect genuine behavior at boundaries that static
repository checks could not fully establish: libkrun's handling of container
identity, the PostgreSQL companion image's initialization assumptions, Valkey's
entrypoint contract, and the interaction between system-level SELinux policy
and mounted ZFS trees. The hostname and PostgreSQL storage tuning in
`1595505`, the Valkey entrypoint adjustment in `1fed545`, and the final
PostgreSQL compatibility work in `82b5705` are reasonable evidence-driven
adjustments rather than arbitrary churn.

The database entrypoint adapter added in `82b5705` is a contained compatibility
boundary for the pinned companion image under libkrun. It makes the image's
effective identity and initialization contract explicit while preserving the
upstream image. It is not debt merely because it is local glue. Revisit it only
if the image contract changes or an upstream release makes the adapter
unnecessary; keep its smoke and contract tests either way.

## Reboot evidence and newly proven bug

The diagnostic report collected on boot `ebf39f1c-592b-418f-9004-5396b931d4e7`
shows SELinux enforcing, Podman 5.8.4, crun 1.28 with libkrun, and no failed
system units overall. The server storage preparation alone failed. Its parent
library directory was `51130:51130`, mode `0750`, and
`container_file_t:s0`, matching the expected label. The first child,
`encoded-video`, was observed as mapped ownership `511300000:511300000`, mode
`1755`, and `unconfined_u:object_r:container_file_t:s0`.

This proves two storage-readiness assumptions that were not previously
covered. The subordinate ID `511300000` is valid for `_nas_immichserver`, but
the old check required every descendant to use the service's primary host ID.
The child also has the required SELinux type and `s0` level, but the old check
required the canonical `system_u` context and rejected `unconfined_u`. Both
observations are valid rootless runtime state, not ownership or label drift.
Their rejection prevented the readiness marker and server startup.

The report also shows a cleanup defect: the explicit-repair refusal was retried
indefinitely, producing dozens of identical failures. That behavior needs a
bounded/fail-stopped policy and a precise mismatch report before another
deployment is considered reboot-safe.

## Cleanup and follow-ups

- Correct the storage contract to accept descendant IDs only from the service
  identity or its assigned subordinate range, and validate the security-
  relevant label type and level (`container_file_t:s0`) without rejecting an
  acceptable SELinux user component. Preserve exact ownership and mode on the
  storage root plus strict mount-source and dataset checks.
- Make deterministic explicit-repair failures stop or back off instead of
  retrying forever, and include the exact path, observed value, and expected
  value in the failure evidence.
- Validate the fix with the affected mapped child and with the other Immich
  storage declarations, then perform a clean reboot and confirm server,
  database, Valkey, ML, TAP policy, and the external health path recover.
- Retain and maintain the database entrypoint adapter, image compatibility
  probe, smoke coverage, and diagnostics; these are valuable compatibility
  boundaries, not cleanup targets.
- If repository-managed Immich backup becomes a requirement, define its
  recovery point as the authoritative library plus a consistent PostgreSQL
  backup, with thumbnails, encoded video, Valkey, and ML caches classified as
  regenerable unless a later requirement changes that decision.

## Recommended sequence

1. Fix and validate reboot recovery, including the storage-readiness bug and
   retry behavior.
2. Add the *arr stack after Immich reboot recovery is boring; use it to expose
   the distinct shared-media, download-handoff, VPN, and application-group
   lifecycle shape.
3. Record an explicit backup-or-no-backup disposition for the new services and
   shared data. Do not treat reproducible media as requiring off-site backup.
4. Revisit repository-managed Immich backup and any generic backup schema only
   when the two concrete application shapes reveal a requirement. Keep
   application membership, storage selection, quiescing/consistency, and
   destinations separate.
