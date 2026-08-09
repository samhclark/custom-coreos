# Documentation map

The live system is described by a small set of authoritative documents. Start
here rather than reading rollout plans or evidence logs.

## Architecture

- [`architecture/secrets.md`](architecture/secrets.md) — encrypted source,
  boot-time distribution, and the rootless runtime-file boundary
- [`architecture/libkrun-networking.md`](architecture/libkrun-networking.md) —
  routed TAP data plane and fail-closed lifecycle
- [`architecture/release-and-testing.md`](architecture/release-and-testing.md) —
  development gates, publishing policy, and deliberately deferred tests

## Development and operations

- [`rootless-quadlet-playbook.md`](rootless-quadlet-playbook.md) — add or
  change a generated rootless service
- [`roadmap.md`](roadmap.md) — current work and settled invariants
- [`jellyfin-monitoring-checklist.md`](jellyfin-monitoring-checklist.md) —
  playback monitoring setup and interpretation
- [`plan-jellyfin-libkrun-hardware-transcoding.md`](plan-jellyfin-libkrun-hardware-transcoding.md)
  — the one active investigation

Completed migration plans and rollout evidence are retained only for
provenance. They are not current instructions and will live under
`docs/history/`.
