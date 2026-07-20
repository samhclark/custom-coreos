# Roadmap: Rootless Platform Migration

This file records the decisions from the July 2026 repo review and the work
remaining. The goal driving all of it: spend time using the NAS, not
maintaining it.

## Decisions (settled — do not re-litigate without new evidence)

1. **Rootless secrets use runtime files, not Podman `Secret=`.**
   The rootful `sops-distribute-secrets.service` decrypts SOPS once at boot
   and writes per-service files under `/run/nas-secrets/<service>/`, owned by
   the service user, mode 0400, mounted `:ro,Z` into containers (relabeling
   `/run` tmpfs files from rootless Podman is NAS-validated). Rootless Podman
   secrets via the shell driver are a validated dead end. Full findings:
   `docs/plan-sops-and-quadlet-generator.md` Appendix D.

2. **libkrun is deferred, and is a per-service dial, not an architecture.**
   Volumes cross into a libkrun microVM via virtiofs (host kernel keeps ZFS;
   no NFS layer needed). Enabling it later is a per-unit runtime flag
   (`PodmanArgs=--runtime krun`), and bind-mounted secret files carry over
   unchanged. Candidates later: small network-facing services. Likely never:
   media-path services where virtiofs overhead lands on the hot path.

3. **Rootless boilerplate is generated, never hand-edited.**
   `quadlets/<service>.toml` + `generate-quadlets.py` produce everything;
   CI fails on drift. The TOMLs double as the secret-routing manifest for
   the distributor.

4. **Everything migrates to rootless except possibly caddy.**
   Caddy binds 80/443; either set `net.ipv4.ip_unprivileged_port_start=80`
   or keep the edge proxy rootful. Rootful-caddy-plus-rootless-everything is
   an acceptable end state.

5. **Service UIDs are allocate-only.** Never reuse a retired UID; numeric
   file ownership (especially in ZFS snapshots) outlives the user. Scheme
   and current allocations live in AGENTS.md; `quadlets/*.toml` is the
   active registry.

## Done (July 2026)

- Distributor rewritten to the runtime-file design; validated on the NAS
  end-to-end, deployed, and verified across two reboots.
- Quadlet generator built; grafana, vmalert, and blackbox-exporter converted
  with no functional diff; CI drift check active.
- Alertmanager migrated to a rootless Quadlet and validated on the NAS,
  including runtime Pushover credentials, health and metrics endpoints,
  Grafana visibility, and successful synthetic-alert delivery to Pushover.
- Cockpit deleted (quadlet, packages, Caddy vhost).

## Remaining work (in order)

- [x] **1. First production rootless secret.** Done 2026-07-04: grafana
      mounts `garage-metrics-token` via the runtime-file path. Verified on
      the NAS: distributor writes the file at boot from the image-shipped
      TOML, grafana's user service starts ~12s later with the ExecStartPre
      guard passing (boot ordering needs no cross-manager dependency), and
      the container reads the mounted file with matching content. The
      missing-file case is bounded by design (guard fails the start;
      Restart=always retries every 30s) and was not observed live. This
      proof-only Grafana mount is removed by the VictoriaMetrics migration;
      VictoriaMetrics becomes the real rootless consumer of that token.
- [ ] **2. Migrate rootful services to rootless**, one at a time, easiest
      first: victoria-metrics → garage → caddy decision. Alertmanager was
      completed and production-validated 2026-07-19. VictoriaMetrics was also
      deployed and production-validated 2026-07-19 using UID `51250`, guarded
      ZFS ownership conversion, and a runtime Garage metrics token. Garage is
      next and uses a two-release plan: rootful hardening/preflight first, then
      the rootless identity and ownership cutover.
      Each migration: new TOML + UID allocation, secrets move from Podman
      `Secret=` to runtime files, then delete the rootful quadlet. When the
      last `Secret=` consumer is gone, delete the shell secret driver
      (`/usr/local/lib/podman-secret-driver/`), `nas-secrets`, and
      `test-podman-secret-driver.sh`. Until then: secret rotation goes
      through `secrets.sops.yaml` + redeploy, never `nas-secrets` alone
      (the distributor's hash check will not correct a manual rotation).
- [ ] **3. Add Renovate** with a custom regex manager for image references
      in `quadlets/*.toml` and the rootful `*.container` files, plus the
      `FROM ghcr.io/getsops/sops:` pin in the Containerfile. Converge every
      service on pinned tags/digests; drop the inert
      `AutoUpdate=`/`Pull=newer` mix. Matters more with every service added.
- [ ] **4. New services** (the actual goal): immich, jellyfin,
      audiobookshelf, *arr — each is one TOML + UID + Containerfile enable
      line + SOPS values + Caddy vhost, per the pipeline below.
- [ ] **5. Small cleanups**, opportunistically:
      - NAS-local cockpit residue (manual, one-time):
        `sudo rm -rf /etc/cockpit` and
        `sudo podman rmi quay.io/cockpit/ws:latest`. The `cockpit-ws`
        passwd entry stays — it ships in Fedora CoreOS's static sysusers,
        not from this repo.
      - Delete `test-systemd-creds.sh` (findings preserved in the plan doc).
      - De-duplicate README.md vs AGENTS.md.
      - Move `zfs-snapshot-*.sh` from `/etc/systemd/system/` to
        `/usr/local/bin/`.

## New-service pipeline

Adding a service should cost: one `quadlets/<name>.toml` (UID from the
scheme in AGENTS.md), `python3 generate-quadlets.py`, one
`systemctl enable ensure-nas-<name>-account.service` line in the
Containerfile, secret values in `secrets.sops.yaml`, a Caddy vhost if
user-facing, and a deploy. Anything beyond that is a defect in the platform
layer and worth fixing there instead of working around per-service.
