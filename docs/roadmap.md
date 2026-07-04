# Roadmap: Rootless Platform Migration

This file records the decisions made during the July 2026 repo review and the
sequenced action items that follow from them. The goal driving all of it:
spend time using the NAS, not maintaining it.

## Decisions (settled — do not re-litigate without new evidence)

1. **Rootless secrets use runtime files, not Podman `Secret=`.**
   The rootful `sops-distribute-secrets.service` decrypts SOPS once at boot
   and writes per-service files under `/run/nas-secrets/<service>/`, owned by
   the service user, mode 0400, mounted read-only into containers. Rootless
   Podman secrets via the shell driver are a validated dead end (the helper
   runs in a user namespace where `systemd-creds` has no usable key mode).
   Full findings: `docs/plan-sops-and-quadlet-generator.md` Appendix D.

2. **libkrun is deferred, and is a per-service dial, not an architecture.**
   Volumes cross into a libkrun microVM via virtiofs (host kernel keeps ZFS;
   no NFS layer needed). Enabling it later is a per-unit runtime flag
   (`PodmanArgs=--runtime krun`), and bind-mounted secret files carry over
   unchanged. Candidates later: small network-facing services. Likely never:
   media-path services (jellyfin, immich) where virtiofs overhead lands on
   the hot path. Nothing in the rootless migration is made harder by
   adopting libkrun later.

3. **The quadlet generator (plan Phase 2) is worth building.**
   Target state is ~10 rootless services (immich, jellyfin, audiobookshelf,
   *arr, plus current). At that count, one TOML per service beats seven
   hand-copied boilerplate files, and the TOML doubles as the secret-routing
   manifest for the distributor.

4. **Everything migrates to rootless except possibly caddy.**
   Caddy binds 80/443; either set `net.ipv4.ip_unprivileged_port_start=80`
   or keep the edge proxy rootful. Rootful-caddy-plus-rootless-everything is
   an acceptable end state. cockpit-ws gets deleted, not migrated.

## Action items (in order)

- [x] **1. Rewrite the rootless branch of `sops-distribute-secrets.sh`.**
      Done 2026-07-03. The rejected design (rootless Podman secret stores via
      `run_podman_as` / `ensure_rootless_store`) is replaced with the
      runtime-file design; the rootful Podman-secret path is unchanged, and
      the state-file format stays compatible. Not yet deployed — ships with
      the next image build.
- [x] **2. Validate the runtime-file design on the NAS.** Done 2026-07-03,
      via ephemeral tests under `/run` (results recorded in
      `docs/plan-sops-and-quadlet-generator.md` Appendix D). Key result:
      `:ro,Z` relabeling of `/run` tmpfs files works from rootless Podman,
      so generated quadlets use `:ro,Z` and the distributor does no
      labeling. The rewritten script also ran end-to-end on the NAS with
      writable paths redirected to a throwaway tree.
- [ ] **3. Build the quadlet generator** per
      `docs/plan-sops-and-quadlet-generator.md` Phase 2. Convert grafana,
      vmalert, and blackbox-exporter first; that deploy must be a no-op.
      Add the CI drift check.
- [ ] **4. Migrate rootful services to rootless**, one at a time, easiest
      first: alertmanager → victoria-metrics → garage → caddy decision.
      Delete cockpit-ws. When the last `Secret=` consumer is gone, delete
      the shell secret driver (`/usr/local/lib/podman-secret-driver/`),
      `nas-secrets`, and `test-podman-secret-driver.sh`.
- [ ] **5. Add Renovate** with a custom regex manager for `Image=` lines in
      `*.container` files (and quadlet TOMLs once the generator lands), plus
      the `FROM ghcr.io/getsops/sops:` pin. Converge every service on
      pinned tags/digests; drop the inert `AutoUpdate=`/`Pull=newer` mix.
      This is the highest-leverage maintenance item once service count grows.
- [ ] **6. Guard against `nas-secrets` ↔ SOPS drift** until item 4 removes
      `nas-secrets` entirely: rotation goes through the SOPS file + redeploy,
      never through `nas-secrets` alone. (The distributor skips secrets whose
      state-file hash matches SOPS, so a manual rotation silently diverges.)
- [ ] **7. Cleanups** (fold in opportunistically): delete
      `test-systemd-creds.sh` (findings preserved in plan Appendix D);
      de-duplicate README.md vs AGENTS.md; move `zfs-snapshot-*.sh` out of
      `/etc/systemd/system/` into `/usr/local/bin`; remove the empty
      `quadlets/` COPY plumbing if the generator design changes it.

## New-service pipeline (after items 1–4)

Adding a service should cost: one `quadlets/<name>.toml`, a UID allocation
from the scheme in AGENTS.md, secret values added to `secrets.sops.yaml`,
one `systemctl enable ensure-nas-<name>-account.service` line in the
Containerfile, and a deploy. Anything beyond that is a defect in the
platform layer and worth fixing there instead of working around per-service.
