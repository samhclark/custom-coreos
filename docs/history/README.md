# Historical evidence

This subtree preserves completed migrations and deployment evidence. It is not
part of the current operational or architectural contract.

Use [`../README.md`](../README.md) for the active documentation map. Current
secret and routed-TAP decisions were extracted into:

- [`../architecture/secrets.md`](../architecture/secrets.md)
- [`../architecture/libkrun-networking.md`](../architecture/libkrun-networking.md)

The files here intentionally retain old commands, paths, rejected designs,
and point-in-time status. Internal links may describe their original location.
Do not "fix" that historical evidence as part of ordinary implementation
work, and never execute its commands against the NAS.

## Contents

- `migrations/` — design, implementation, and evidence logs for completed
  platform migrations
- `deployments/` — one-time preflight and rollout checklists for completed
  service deployments

Recent deployment retrospectives:

- [`deployments/immich.md`](deployments/immich.md) — Immich rollout churn,
  reboot evidence, storage-readiness findings, and sequencing recommendation
